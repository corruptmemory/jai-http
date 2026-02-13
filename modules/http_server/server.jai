
LISTEN_BACKLOG :: 1024;

Worker :: struct {
    engine:       Event_Engine;
    pool:         Connection_Pool;
    listen_fd:    s32 = -1;
    listen_conn:  *Connection;     // Sentinel connection for the listen socket
    running:      bool;
    id:           s32;
    router:       *Router;
    request_pool: Pool_Module.Pool;  // Per-request allocator, reset after each dispatch
    thread:       Thread;
}

Server :: struct {
    workers:       [] Worker;
    num_workers:   s32;
    running:       bool;
    router:        *Router;
    data_to_free:  *void;
}

init_server :: (server: *Server, num_workers: s32 = 16, pool_size: s64 = 1024) -> bool {
    server.num_workers = num_workers;
    server.workers, server.data_to_free = Basic.NewArray(cast(s64) num_workers, Worker, true);

    for i: 0..cast(s64) num_workers - 1 {
        w := *server.workers[i];
        w.id = cast(s32) i;

        ok := init_event_engine(*w.engine);
        if !ok {
            Basic.log_error("Failed to init event engine for worker %", i);
            j := i - 1;
            while j >= 0 {
                destroy_worker(*server.workers[j]);
                j -= 1;
            }
            return false;
        }

        // +1 for the listen socket sentinel
        init_pool(*w.pool, pool_size + 1);

        // Set up the per-request pool allocator's backing allocator
        Pool_Module.set_allocators(*w.request_pool);
    }

    return true;
}

serve :: (server: *Server, router: *Router) {
    server.router = router;
}

destroy_server :: (server: *Server) {
    for i: 0..cast(s64) server.num_workers - 1 {
        destroy_worker(*server.workers[i]);
    }
    if server.data_to_free {
        Basic.free(server.data_to_free);
        server.data_to_free = null;
    }
}

// Each worker creates its own socket with SO_REUSEPORT, binds, and listens.
// The kernel distributes incoming connections across workers.
server_listen :: (server: *Server, address: string, port: u16) -> bool {
    for i: 0..cast(s64) server.num_workers - 1 {
        ok := worker_listen(*server.workers[i], address, port);
        if !ok {
            Basic.log_error("Worker % failed to listen", i);
            return false;
        }
    }

    Basic.print("Listening on %:% with % workers\n", address, port, server.num_workers);
    return true;
}

// Start all worker threads and block until shutdown.
// Worker 0 runs on the main thread; workers 1..N-1 get their own threads.
server_run :: (server: *Server) {
    server.running = true;

    // Copy router to all workers
    for i: 0..cast(s64) server.num_workers - 1 {
        server.workers[i].router = server.router;
    }

    // Start worker threads (workers 1..N-1)
    for i: 1..cast(s64) server.num_workers - 1 {
        w := *server.workers[i];
        w.running = true;
        thread_init(*w.thread, worker_thread_proc);
        w.thread.data = w;
        thread_start(*w.thread);
    }

    // Worker 0 runs on the main thread
    server.workers[0].running = true;
    worker_run(*server.workers[0]);

    // Wait for all worker threads to finish
    for i: 1..cast(s64) server.num_workers - 1 {
        w := *server.workers[i];
        thread_is_done(*w.thread, -1);
        thread_deinit(*w.thread);
    }
}

#scope_file

worker_thread_proc :: (thread: *Thread) -> s64 {
    w := cast(*Worker) thread.data;
    worker_run(w);
    return 0;
}

worker_listen :: (w: *Worker, address: string, port: u16) -> bool {
    s := socket(AF_INET, .SOCK_STREAM | .SOCK_NONBLOCK | .SOCK_CLOEXEC, 0);
    if s == INVALID_SOCKET {
        Basic.log_error("Worker %: socket() failed: %", w.id, get_error_string(get_last_socket_error()));
        return false;
    }

    opt: s32 = 1;
    if setsockopt(s, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, xx *opt, size_of(type_of(opt))) < 0 {
        Basic.log_error("Worker %: setsockopt failed: %", w.id, get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }

    if bind(s, address, port) < 0 {
        Basic.log_error("Worker %: bind failed: %", w.id, get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }

    if listen(s, LISTEN_BACKLOG) < 0 {
        Basic.log_error("Worker %: listen failed: %", w.id, get_error_string(get_last_socket_error()));
        close_and_reset(*s);
        return false;
    }

    // Use a pool connection as sentinel for the listen socket
    w.listen_conn = get_connection(*w.pool);
    if w.listen_conn == null {
        Basic.log_error("Worker %: no connections available for listen socket", w.id);
        close_and_reset(*s);
        return false;
    }
    w.listen_conn.fd = s;
    w.listen_fd = s;

    // Register listen socket with epoll (edge-triggered)
    ok := epoll_add_connection(*w.engine, w.listen_conn, EPOLLIN | EPOLLET);
    if !ok {
        close_and_reset(*s);
        return false;
    }

    return true;
}

worker_run :: (w: *Worker) {
    while w.running {
        nfds := epoll_process_events(*w.engine, timeout_ms = -1);
        if nfds < 0 {
            err := errno();
            if err == EINTR continue;
            Basic.log_error("Worker %: epoll_wait failed: %", w.id, err);
            continue;
        }

        for i: 0..nfds-1 {
            ev := *w.engine.events[i];
            c, event_instance := decode_connection_ptr(ev.data.ptr);

            // Stale event check
            if event_instance != c.instance continue;

            if c == w.listen_conn {
                accept_connections(w);
            } else {
                handle_client(w, c, ev.events);
            }
        }
        Basic.reset_temporary_storage();
    }
}

destroy_worker :: (w: *Worker) {
    if w.listen_fd != -1 {
        close(w.listen_fd);
        w.listen_fd = -1;
    }
    destroy_event_engine(*w.engine);
    destroy_pool(*w.pool);
    Pool_Module.release(*w.request_pool);
}

accept_connections :: (w: *Worker) {
    while true {
        addr: sockaddr_in;
        addrlen: u32 = size_of(sockaddr_in);
        conn_fd := accept4(w.listen_fd, cast(*sockaddr) *addr, xx *addrlen, .NONBLOCK | .CLOEXEC);

        if conn_fd < 0 break;  // EAGAIN — no more pending

        c := get_connection(*w.pool);
        if c == null {
            close(conn_fd);
            continue;
        }
        c.fd = conn_fd;

        ok := epoll_add_connection(*w.engine, c, EPOLLIN | EPOLLET | EPOLLRDHUP);
        if !ok {
            close(conn_fd);
            free_connection(*w.pool, c);
        }
    }
}

handle_client :: (w: *Worker, c: *Connection, events: u32) {
    // Error or hangup
    if events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP) {
        close_connection(w, c);
        return;
    }

    if events & EPOLLIN {
        // Edge-triggered: read until EAGAIN
        while true {
            available := READ_BUFFER_SIZE - c.bytes_used;
            if available <= 0 {
                // Buffer full but request incomplete — too large
                close_connection(w, c);
                return;
            }

            bytes_read := read(c.fd, c.buf.data + c.bytes_used, xx available);
            if bytes_read < 0 {
                err := errno();
                if err == EAGAIN || err == EWOULDBLOCK break;
                close_connection(w, c);
                return;
            }
            if bytes_read == 0 {
                close_connection(w, c);
                return;
            }

            c.bytes_used += bytes_read;

            // Process complete requests (handles pipelining)
            while true {
                result := parse_request(c);
                if result == .COMPLETE {
                    response: Response;

                    // Dispatch through router with per-request pool allocator
                    new_ctx := context;
                    new_ctx.allocator = .{Pool_Module.pool_allocator_proc, *w.request_pool};
                    push_context new_ctx {
                        dispatch(w.router, *c.req, *response);
                    }
                    Pool_Module.reset(*w.request_pool);

                    write_response(c.fd, *response, c.req.keep_alive);

                    if !c.req.keep_alive {
                        close_connection(w, c);
                        return;
                    }

                    reset_for_next_request(c);
                } else if result == .ERROR {
                    close_connection(w, c);
                    return;
                } else {
                    break;  // INCOMPLETE — need more data
                }
            }
        }
    }
}

close_connection :: (w: *Worker, c: *Connection) {
    epoll_del_connection(*w.engine, c);
    close(c.fd);
    free_connection(*w.pool, c);
}

#import "System";
