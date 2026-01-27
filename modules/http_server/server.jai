
LISTEN_QUEUE_LENGTH :: 10;

HTTP_EOL :: "\r\n";
WHITESPACE :: " \t";

Channel :: struct(T: Type) {
    data_to_free: *void;
    items:        [] T;
    head:         int;
    tail:         int;
    lock:         Mutex;
    read_cond:    Condition_Variable;
    write_cond:   Condition_Variable;
    closed:       bool;
}

destroy :: (using channel: *Channel($T)) {
    assert(data_to_free != null);
    free(data_to_free);
    data_to_free = null;
    destroy(*lock);
    destroy(*read_cond);
    destroy(*write_cond);
}

init :: (using channel: *Channel($T), count: int) {
    assert(count > 0);
    items, data_to_free = Basic.NewArray(count, T, true);
    init(*lock);
    init(*read_cond);
    init(*write_cond);
}

send :: (channel: *Channel($T), item: T) {
    defer unlock(*channel.lock);
    defer wake(*channel.read_cond);
    lock(*channel.lock);

    if channel.closed return;
    while channel.tail-channel.head == channel.items.count {
        wait(*channel.write_cond, *channel.lock);        
    }
    channel.items[channel.tail % channel.items.count] = item;
    channel.tail += 1;
}

receive :: (channel: *Channel($T)) -> T {
    defer unlock(*channel.lock);
    defer wake(*channel.write_cond);
    lock(*channel.lock);

    if channel.closed return .{};    
    while channel.head == channel.tail {
        wait(*channel.read_cond, *channel.lock);        
    }
    item := channel.items[channel.head];
    channel.head += 1;
    if channel.head >= channel.items.count {
        channel.head -= channel.items.count;
        channel.tail -= channel.items.count;
    }
    return item;
}

Accept_Handler_Entry :: struct {
    socket:       Socket;
    remote:       sockaddr_in;
}

Accept_Handler :: #type (server: *Server, handler_data: *Accept_Handler_Entry, data: *void);

Server :: struct {
    allocator:                   Allocator;
    listen_socket:               Socket;
    handler_data:                *void;
    handler_proc:                Accept_Handler;
    listening_thread:            Thread;
    threads:                     [] Thread;
    threads_data_to_free:        *void;
    channel:                     Channel(Accept_Handler_Entry);
}

add_work :: (s: *Server, socket: Socket, remote: sockaddr_in) {
    send(*s.channel, .{
            socket = socket,
            remote = remote
        });
}

consume :: (s: *Server) -> Accept_Handler_Entry {
    return receive(*s.channel);
}

Default_Handler_Data :: struct {
    max_header_size: u32 = 64*1024;
}

DEFAULT_HANDLER_DATA: Default_Handler_Data = .{};

Request_Header :: struct {
    name: string;
    value: string;
}

Request_Method :: enum u8 {
    GET;
    POST;
    PUT;
    PATCH;
    DELETE;
    HEAD;
    OPTIONS;
    CONNECT;
    TRACE;
};

Method_Map :: struct {
    name: string;
    method: Request_Method;
}

generate_method_map :: () -> string {
    method_map_ti := cast(*Type_Info_Enum) type_info(Request_Method);
    builder: String_Builder;

    print_to_builder(*builder, "Method_Map.[\n");
    for method_map_ti.values {
        name := method_map_ti.names[it_index]; 
        print_to_builder(*builder, "{ \"%\", .% },\n", name, name);
    }
    print_to_builder(*builder, "];");

    result := builder_to_string(*builder);

    return result;
}

method_map :: #insert #run generate_method_map();

Request :: struct {
    socket:           Socket;
    data_raw:         []u8;
    request_line_raw: []u8;
    header_raw:       []u8;
    body_begin_raw:   []u8; 
    body_offset:      s64;
    method:           Request_Method;
    method_raw:       string;
    path_raw:         string;
    version_raw:      string;
    headers:          []Request_Header;
}

Advance_Result :: enum u8 {
    OK;
    EOL;
    EOB;
};


Response :: struct {
    
}

advance_array :: inline (array: [] u8, bytes: s64) -> result: [] u8 {
    assert(array.count >= bytes);

    result := array;
    result.data  += bytes;
    result.count -= bytes;

    return result;
}


is_eol :: inline (array: [] u8) -> (ok: bool, result: [] u8) {
    if array.count < 2 return false, array;
    if array[0] == #char "\r" && array[1] == #char "\n" return true, advance_array(array, 2);
    return false, array;
}

is_eol_at :: inline (array: [] u8, at: s64) -> bool {
    if (array.count - at) < 2 return false;
    if array[at] == #char "\r" && array[at+1] == #char "\n" return true;
    return false;
}

advance_past_whitespace :: (buffer: []u8) -> (capture: string, result: Advance_Result, remaining: []u8) {
    cursor := 0;
    remaining := buffer;
    while cursor < buffer.count {
        if is_any(buffer[cursor], WHITESPACE) {
            cursor += 1;
            continue;
        };
        remaining = advance_array(buffer,cursor);
        iseol, rem := is_eol(remaining);
        if iseol return "", .EOL, rem;
        break;
    }
    if remaining.count == 0 return "", .EOB, remaining;
    cursor = 0;
    capture := cast(string) remaining;
    while cursor < remaining.count {
        if is_any(remaining[cursor], WHITESPACE) {
            capture.count = cursor;
            return capture, .OK, advance_array(remaining, cursor);
        };
        if is_eol_at(remaining, cursor) {
            capture.count = cursor;
            return capture, .EOL, advance_array(remaining, cursor+HTTP_EOL.count);
        }
        cursor += 1;
    }
    capture.count = cursor;
    return capture, .EOB, advance_array(remaining, cursor);
}

parse_request_line :: (buffer: []u8, request: *Request) -> (ok: bool, remaining: []u8) {
    method: string;
    path: string;
    version: string;
    res: Advance_Result;
    nb: []u8;
    method, res, nb = advance_past_whitespace(buffer);
    if res != .OK {
        log_error("Could not parse method");
        return false, buffer;
    }
    request.request_line_raw = buffer;
    for method_map {
        if it.name == method {
            request.method_raw = method;
            request.method = it.method;
            break;
        }
    }
    if request.method_raw.count == 0 {
        log_error("Could not decode method");
        return false, buffer;
    }
    path, res, nb = advance_past_whitespace(nb);
    if res != .OK {
        log_error("Could not parse path");
        return false, buffer;
    }
    request.path_raw = path;
    version, res, nb = advance_past_whitespace(nb);
    if res != .EOL {
        log_error("Could not parse version");
        return false, buffer;
    }
    request.version_raw = version;
    request.request_line_raw.count = cast(s64)(nb.data) - cast(s64)(buffer.data) - HTTP_EOL.count;
    return true, nb;
}

parse_request_from_buffer :: (buffer: []u8, request: *Request) -> (ok: bool) {
    return false;
}

parse_request :: (max_header_size: int ,accept_data: *Accept_Handler_Entry, request: *Request) -> (ok: bool) {
    request.data_raw = Basic.NewArray(max_header_size, u8, true);
    actually_read := read(accept_data.socket, request.data_raw.data, xx request.data_raw.count);
    // print("data: %\n", cast(string) request.data_raw);
    return false;
}

response :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\nHello, World!";

send_hello_world :: (client_fd: s32) -> bool {
    // 1. Define the response with explicit CRLF (\r\n)
    // The Content-Length is 13 ("Hello, World!" is 13 characters)

    remaining := response.count;
    offset    := 0;

    // 2. Loop until all bytes are sent (Handling partial writes)
    while remaining > 0 {
        bytes_sent := write(client_fd, response.data + offset, xx remaining);

        if bytes_sent < 0 {
            // Handle error (e.g., connection reset or interrupted)
            error_code := errno();
            if error_code == EINTR continue; // Interrupted by signal, try again
            
            log_error("Write failed with errno: %", error_code);
            return false;
        }

        remaining -= bytes_sent;
        offset    += bytes_sent;
    }

    return true;
}

default_handler :: (server: *Server, accept_data: *Accept_Handler_Entry, data: *void) {
    handler_data := cast(*Default_Handler_Data)data;
    if accept_data.socket == 0
      log("WTF: %", accept_data.socket);
    request: Request;
    parse_request(handler_data.max_header_size, accept_data, *request);
    send_hello_world(accept_data.socket);
    close_and_reset(*accept_data.socket);
}


init_server :: (using server: *Server, backlog_size: u32 = 256, thread_count: s16 = 0, in_handler_proc: Accept_Handler = default_handler, in_handler_data: *void = *DEFAULT_HANDLER_DATA) {
    if thread_count <= 0 {
        thread_count = cast(s16) get_number_of_processors(type=.ALL_PHYSICAL) - 1;
    }
    Basic.remember_allocators(server);
    init(*channel, backlog_size);
    threads, threads_data_to_free = Basic.NewArray(thread_count, Thread, true, alignment=CACHE_LINE_SIZE,, server.allocator);
    handler_data = in_handler_data;
    handler_proc = in_handler_proc;

    thread_proc :: (thread: *Thread) -> s64 {
        server := cast(*Server) thread.data;
        handler := server.handler_proc;
        handler_data := server.handler_data;

        raw_request: Accept_Handler_Entry = ---;
        ok: bool = ---;
        while (1) {
            raw_request = consume(server);
            handler(server, *raw_request, handler_data,, allocator=temp);
            reset_temporary_storage();
        }
        return 0;
    }

    for * threads {
        it.data = server;
        thread_init(it, thread_proc);
    }
    
}


listen :: (using server: *Server, address: string, port: u16) -> bool {
    s := socket(AF_INET, .SOCK_STREAM, 0);
    if s == 0 {
        log("error getting socket: %", get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }
    opt := cast(s32)1;
    if setsockopt(s, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, xx *opt, size_of(type_of(opt))) < 0 {
        log("error setting socket options: %", get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }
    if bind(s, address, port) < 0 {
        log("error binding socket: %", get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }
    listen_socket = s;
    listen_proc :: (thread: *Thread) -> s64 {
        server := cast(*Server) thread.data;
        defer close_and_reset(*server.listen_socket);
        if listen(server.listen_socket, LISTEN_QUEUE_LENGTH) < 0 {
            log("error binding socket: %", get_error_string(get_last_socket_error()));
            return -1;
        }
        log("listening...");
        while (1) {
            // log("waiting to accept...");
            accept_socket, in_addr := accept(server.listen_socket);
            if accept_socket < 0 {
                log("error accepting connection: %", get_error_string(get_last_socket_error()));
                continue;
            }
            // log("accepted!");
            add_work(server, accept_socket, in_addr);
        }
        return 0;
    }
    server.listening_thread.data = server;
    thread_init(*server.listening_thread, listen_proc);
    for * threads {
        thread_start(it);
    }
    thread_start(*server.listening_thread);
    return true;
}


#import "System";
#import "Socket";
#import "Thread";
#import "Machine_X64";
#import "Atomics";
#import "Basic";
#import "String";
#import "POSIX";
#import "Machine_X64";
