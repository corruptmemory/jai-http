
LISTEN_QUEUE_LENGTH :: 10;

HTTP_EOL :: "\r\n";

Accept_Handler_Entry :: struct {
    socket:       Socket;
    remote:       sockaddr_in;
}


Accept_Handler_Entry_Padded :: struct {
    using base: Accept_Handler_Entry;
    BASE_SIZE    :: size_of(type_of(base));
    PADDING_SIZE :: #run Basic.align_forward(BASE_SIZE, CACHE_LINE_SIZE) - BASE_SIZE;
        
    padding: [PADDING_SIZE] u8;
}

Accept_Handler :: #type (server: *Server, handler_data: *Accept_Handler_Entry, data: *void);

Server :: struct {
    listen_socket:               Socket;
    handler_data:                *void;
    handler_proc:                Accept_Handler;
    allocator:                   Allocator;
    listening_thread:            Thread;
    threads:                     [] Thread;
    threads_data_to_free:        *void;
    accept_handler_data_to_free: *void;
    mask:                        u64 #align CACHE_LINE_SIZE;
    running:                     int #align CACHE_LINE_SIZE;
    head:                        u64 #align CACHE_LINE_SIZE;
    tail:                        u64 #align CACHE_LINE_SIZE;
    entries:                     [] Accept_Handler_Entry_Padded #align CACHE_LINE_SIZE;
}

is_power_of_2 :: (n: u32) -> bool {
    return n && !(n & (n - 1));
}

try_add_work :: (s: *Server, socket: Socket, remote: sockaddr_in) -> bool {
    h := atomic_read(*s.head);
    t := atomic_read(*s.tail);

    if cast(s64)(h - t) >= s.entries.count {
        return false; 
    }

    s.entries[h & s.mask].base = .{
        socket = socket,
        remote = remote
    };

    atomic_write(*s.head, h + 1);
    return true;
}

try_consume :: (s: *Server) -> (result: Accept_Handler_Entry, ok: bool) {
    t: u64 = ---;
    h: u64 = ---;
    
    while (1) {
        h = atomic_read(*s.head);
        t = atomic_read(*s.tail);

        if t >= h break;

        if compare_and_swap(*s.tail, t, t + 1)
            return s.entries[t & s.mask].base, true;
    }
    return .{}, false;
}

Default_Handler_Data :: struct {
    max_header_size: u32 = 64*1024;
}

DEFAULT_HANDLER_DATA: Default_Handler_Data = .{};

Request_Header :: struct {
    name: string;
    value: string;
}

Request_Verb :: enum u8 {
    GET;
    POST;
    HEAD;
    PUT;
};

Request :: struct {
    socket:      Socket;
    verb:        Request_Verb;
    target_raw:  []string;
    version_raw: []string;
    header_raw:  []u8;
    body_offset: u32;
    headers:     []Request_Header;
}

Response :: struct {
    
}

default_handler :: (server: *Server, accept_data: *Accept_Handler_Entry, data: *void) {
    handler_data := cast(*Default_Handler_Data)data;
    log("handler called with %", accept_data);
    if accept_data.socket == 0
      log("WTF: %", accept_data.socket);
    close_and_reset(*accept_data.socket);
}


init_server :: (using server: *Server, backlog_size: u32 = 256, thread_count: s16 = 0, in_handler_proc: Accept_Handler = default_handler, in_handler_data: *void = *DEFAULT_HANDLER_DATA) {
    if thread_count <= 0 {
        thread_count = cast(s16) get_number_of_processors(type=.ALL_PHYSICAL) - 1;
    }
    assert(is_power_of_2(backlog_size));
    Basic.remember_allocators(server);
    entries, accept_handler_data_to_free = Basic.NewArray(backlog_size, Accept_Handler_Entry_Padded, true, alignment=CACHE_LINE_SIZE,, server.allocator);
    threads, threads_data_to_free = Basic.NewArray(thread_count, Thread, true, alignment=CACHE_LINE_SIZE,, server.allocator);
    handler_data = in_handler_data;
    handler_proc = in_handler_proc;
    assert((cast(u64) *head) % cast(u64) CACHE_LINE_SIZE == 0);
    assert((cast(u64) *tail) % cast(u64) CACHE_LINE_SIZE == 0);
    assert((cast(u64) *mask) % cast(u64) CACHE_LINE_SIZE == 0);
    mask = backlog_size - 1;
    atomic_write(*head, 0);
    atomic_write(*tail, 0);
    atomic_write(*running, 0);

    thread_proc :: (thread: *Thread) -> s64 {
        server := cast(*Server) thread.data;
        handler := server.handler_proc;
        handler_data := server.handler_data;

        raw_request: Accept_Handler_Entry = ---;
        ok: bool = ---;
        while (1) {
            raw_request, ok = try_consume(server);
            if !ok continue;
            handler(server, *raw_request, handler_data);
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
            log("waiting to accept...");
            accept_socket, in_addr := accept(server.listen_socket);
            if accept_socket < 0 {
                log("error accepting connection: %", get_error_string(get_last_socket_error()));
                continue;
            }
            log("accepted!");
            while !try_add_work(server, accept_socket, in_addr) {}
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
