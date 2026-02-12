
HTTP_EOL :: "\r\n";
WHITESPACE :: " \t";
MAX_EVENTS :: 1024;
LISTEN_QUEUE_LENGTH :: 1024;


Accept_Handler_Entry :: struct {
    socket:       Socket;
    remote:       sockaddr_in;
}

Accept_Handler :: #type (server: *Server, handler_data: *Accept_Handler_Entry, data: *void);

Server :: struct {
    allocator:                   Allocator;
    epoll_fd:                    s32;
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

drain :: (socket: Socket, target: []u8) -> bool {
    current := target;
    while true {
        count := read(socket, current.data, xx current.count);
        if count == -1 {
            if (get_last_socket_error() != EAGAIN) {
                return false;
            }
            break;
        } else if (count == 0) {
            return false;
        }
        current = advance_array(current, count);
    }
    return true;
}

parse_request :: (max_header_size: int ,accept_data: *Accept_Handler_Entry, request: *Request) -> (ok: bool) {
    request.data_raw = Basic.NewArray(max_header_size, u8, true);
    ok := drain(accept_data.socket, request.data_raw);
    if !ok return false;
    // print("data: %\n", cast(string) request.data_raw);
    return true;
}

response :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\nHello, World!";

send_hello_world :: (client_fd: s32) -> bool {
    remaining := response.count;
    offset    := 0;

    while remaining > 0 {
        bytes_sent := write(client_fd, response.data + offset, xx remaining);

        if bytes_sent < 0 {
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
    ok := parse_request(handler_data.max_header_size, accept_data, *request);
    // log("%\n", cast(string)request.data_raw);
    send_hello_world(accept_data.socket);
    if ok {
        ev := epoll_event.{
            events = EPOLLIN | EPOLLET | EPOLLRDHUP,
            data.fd = accept_data.socket,
        };
        epoll_ctl(server.epoll_fd, Epoll_Ctl.ADD, accept_data.socket, *ev);        
    } else {
        close_and_reset(*accept_data.socket);    
    }
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

Accept_Address :: struct {
    conn_fd: s32;
    addr: sockaddr_in;
}

push_accept_address :: (store: []Accept_Address, conn_fd: s32, addr: sockaddr_in) {
    for * store {
        if it.conn_fd == 0 {
            it.conn_fd = conn_fd;
            it.addr = addr;
            return;
        }
    }
    log_error("error: could not record accept address");
    exit(-1);
}

pop_accept_address :: (store: []Accept_Address, conn_fd: s32) -> sockaddr_in {
    for * store {
        if it.conn_fd == conn_fd {
            it.conn_fd = 0;
            return it.addr;
        }
    }
    log_error("error: could not find record address");
    exit(-1);
    return .{};
}


listen :: (using server: *Server, address: string, port: u16) -> bool {
    epoll_fd = epoll_create1(0);
    if epoll_fd == -1 {
        log_error("error creating epoll fd\n");
        return false;
    }
    s := socket(AF_INET, .SOCK_STREAM | .SOCK_NONBLOCK | .SOCK_CLOEXEC, 0);
    if s == 0 {
        log_error("error getting socket: %\n", get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }
    opt := cast(s32)1;
    if setsockopt(s, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, xx *opt, size_of(type_of(opt))) < 0 {
        log_error("error setting socket options: %\n", get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }
    if bind(s, address, port) < 0 {
        log_error("error binding socket: %\n", get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }
    ev := epoll_event.{
        events = EPOLLIN | EPOLLET,
        data.fd   = s, 
    };
    listen_socket = s;
    if epoll_ctl(epoll_fd, Epoll_Ctl.ADD, s, *ev) {
        log_error("error adding listen socket to epoll fd\n");
        close_and_reset(*s);
        return false;
    };
    listen_proc :: (thread: *Thread) -> s64 {
        server := cast(*Server) thread.data;
        defer close_and_reset(*server.epoll_fd);
        defer close_and_reset(*server.listen_socket);
        defer log("listen proc exiting\n");
        events: [MAX_EVENTS]epoll_event;
        accepted_addresses: []Accept_Address;
        accepted_addresses_data_to_free: *void;
        accepted_addresses, accepted_addresses_data_to_free = Basic.NewArray(4096, Accept_Address, true);
        defer free(accepted_addresses_data_to_free);
        // log("listening...\n");
        if listen(server.listen_socket, LISTEN_QUEUE_LENGTH) < 0 {
            log_error("error binding socket: %\n", get_error_string(get_last_socket_error()));
            return -1;
        }

        ev: epoll_event;
        
        while true {
            // log("beginning epoll_wait\n");
            nfds := epoll_wait(server.epoll_fd, events.data, MAX_EVENTS, -1);
            // log("got something: %\n", nfds);
            if nfds < 0 {
                log_error("failure to get epoll events\n");
                continue;
//                return -1;
            }
            for i: 0..nfds-1 {
                if events[i].data.fd == server.listen_socket {
                    // log("listen socket\n");
                    while true {
                        addr: sockaddr_in;
                        addrlen: u32 = size_of(sockaddr_in);
                        conn_fd := accept4(server.listen_socket,cast(*sockaddr)*addr, xx *addrlen, .NONBLOCK | .CLOEXEC);
                        // log("accepted: %\n", conn_fd);
                        if (conn_fd < 0) break;
//                        push_accept_address(accepted_addresses, conn_fd, addr);
                        
                        ev.events = EPOLLIN | EPOLLET | EPOLLRDHUP;
                        ev.data.fd = conn_fd;
                        epoll_ctl(server.epoll_fd, Epoll_Ctl.ADD, conn_fd, *ev);
                    }
                } else {
                    // log("accept socket has data\n");
                    // Connection ready - remove from epoll and hand to thread pool
                    conn_fd := events[i].data.fd;
                    epoll_ctl(server.epoll_fd, Epoll_Ctl.DEL, conn_fd, null);
                    //addr := pop_accept_address(accepted_addresses, conn_fd);
                    add_work(server, conn_fd, .{});
                }
            }
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

#load "channel.jai";

#import "System";
#import "Socket";
#import "Thread";
#import "Machine_X64";
#import "Atomics";
#import "Basic";
#import "String";
#import "POSIX";
#import "Machine_X64";
#import "Linux";
