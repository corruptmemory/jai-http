
// `Handler` (the core server's only contract) is defined in http.jai as #type (request, response).
// The router (router.jai) is just one Handler built on top; Route_Handler is structurally identical
// — a route handler IS a handler. Bound state is reached via the context, not a parameter (below).
//
// The handler's bound state ("receiver"), delivered ambiently through the context rather than
// as a parameter (Jai has no closures). Its type is the `Handler_Data` program parameter:
// `*void` by default (generic), or a concrete `*T` when the consumer injects one — then it is
// type-safe with no cast in handler code. The core never inspects it; only the handler does.
#add_context handler_data: *Handler_Data;

Worker :: struct {
    engine:       Event_Engine;
    pool:         Connection_Pool;
    listen_fd:    s32 = -1;
    listen_conn:  *Connection;     // Sentinel connection for the listen socket
    running:      bool;
    id:           s32;
    handler:      Handler;
    handler_data: *Handler_Data;
    request_pool: Pool_Module.Pool;  // Per-request allocator, reset after each dispatch
    date:         string;            // cached IMF-fixdate for this second (a view into date_buf); empty omits Date
    date_buf:     [29] u8;
    date_second:  s64 = -1;
    thread:       Thread;
}

Server :: struct {
    workers:       [] Worker;
    num_workers:   s32;
    running:       bool;
    handler:       Handler;
    handler_data:  *Handler_Data;
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

// Wire a handler into the server. `data` is the handler's bound state; it reaches every
// invocation via context.handler_data. Routing is NOT special here — the router installs
// itself through this same path (see the serve(*Server, *Router) overload in router.jai).
serve :: (server: *Server, handler: Handler, data: *Handler_Data = null) {
    server.handler      = handler;
    server.handler_data = data;
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

    // Copy the handler + its bound data to every worker (shared-nothing: each owns a copy).
    for i: 0..cast(s64) server.num_workers - 1 {
        server.workers[i].handler      = server.handler;
        server.workers[i].handler_data = server.handler_data;
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

// Monotonic milliseconds for the timeout stamps. CLOCK_MONOTONIC_COARSE is the kernel's tick
// counter read through the vDSO: no TSC read and no S128 math (seconds_since_init does both), at
// a few ms of resolution, ample for timeouts measured in seconds. Called on every request.
now_ms :: inline () -> s64 {
    ts: timespec;
    clock_gettime(.MONOTONIC_COARSE, *ts);
    return cast(s64) ts.tv_sec * 1000 + cast(s64) ts.tv_nsec / 1000000;
}

// Refresh the cached Date value when the wall-clock second has changed. Called once per epoll
// batch; a batch lasts microseconds, so a response is never more than a batch stale.
refresh_date :: (w: *Worker) {
    now := Basic.current_time_consensus();
    sec, ok := Basic.to_seconds(now);
    if !ok  return;                  // keep the previous value; not worth a per-batch error
    if sec == w.date_second  return;
    w.date_second = sec;
    w.date = format_http_date(Basic.to_calendar(now, .UTC), *w.date_buf);
}

// -- Timeouts --
//
// A connection is bounded by one timeout at a time, chosen by what it is waiting for. A request
// that has fully arrived has no deadline: the handler runs synchronously and request_start_ms is
// cleared before dispatch. Sweeps run once a second from worker_run when any timeout is enabled.

TIMEOUTS_ENABLED :: IDLE_TIMEOUT_MS > 0 || HEADER_TIMEOUT_MS > 0 || BODY_TIMEOUT_MS > 0 || WRITE_TIMEOUT_MS > 0;

Timeout_State :: enum u8 #specified {
    NONE   :: 0;
    IDLE   :: 1;   // between requests
    HEADER :: 2;   // request begun, headers incomplete
    BODY   :: 3;   // headers complete, body incomplete
    WRITE  :: 4;   // response tail pending
}

timeout_state :: (c: *Connection) -> Timeout_State {
    if c.pending.count > 0        return .WRITE;
    if c.bytes_used == 0          return .IDLE;
    if c.parse_state == .BODY     return .BODY;
    if c.parse_state == .COMPLETE return .NONE;   // never observed by the sweep; defensive
    return .HEADER;
}

is_timed_out :: (c: *Connection, now: s64) -> (timed_out: bool, state: Timeout_State) {
    state := timeout_state(c);
    limit: s64 = 0;
    since: s64 = 0;
    if state == {
        case .IDLE;   limit = IDLE_TIMEOUT_MS;   since = c.last_activity_ms;
        case .WRITE;  limit = WRITE_TIMEOUT_MS;  since = c.last_activity_ms;
        case .HEADER; limit = HEADER_TIMEOUT_MS; since = c.request_start_ms;
        case .BODY;   limit = BODY_TIMEOUT_MS;   since = c.request_start_ms;
        case;         return false, state;
    }
    if limit <= 0  return false, state;
    return now - since >= limit, state;
}

// Close every active connection whose timeout has passed. Returns how many were closed. A slow
// request gets a 408 through refuse_and_close: the client may still be sending, so the reply
// needs the same drain-before-close to survive.
check_timeouts :: (w: *Worker, now: s64) -> s32 {
    closed: s32 = 0;
    for * w.pool.connections {
        c := it;
        if c.state != .ACTIVE || c == w.listen_conn  continue;
        timed_out, state := is_timed_out(c, now);
        if !timed_out  continue;
        Basic.log("fd %: % timeout; closing", c.fd, state);
        if state == .HEADER || state == .BODY  refuse_and_close(w, c, 408);
        else                                   close_connection(w, c);
        closed += 1;
    }
    return closed;
}

accept_connections :: (w: *Worker) {
    while true {
        addr: sockaddr_in;
        addrlen: u32 = size_of(sockaddr_in);
        conn_fd := accept4(w.listen_fd, cast(*sockaddr) *addr, xx *addrlen, .NONBLOCK | .CLOEXEC);

        if conn_fd < 0 break;  // EAGAIN — no more pending

        // Disable Nagle's algorithm — send response bytes immediately
        nodelay: s32 = 1;
        setsockopt(conn_fd, xx IPPROTO.TCP, TCP_NODELAY, xx *nodelay, size_of(type_of(nodelay)));

        c := get_connection(*w.pool);
        if c == null {
            Basic.log("fd %: connection pool exhausted; dropping", conn_fd);
            close(conn_fd);
            continue;
        }
        c.fd = conn_fd;
        c.last_activity_ms = now_ms();

        // Write interest is armed once for the connection's whole life. Edge-triggered OUT only
        // fires on the full-to-writable transition, so it costs nothing while there is room, and
        // a stalled response never needs an epoll_ctl MOD to be resumed.
        ok := epoll_add_connection(*w.engine, c, EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP);
        if !ok {
            close(conn_fd);
            free_connection(*w.pool, c);
        }
    }
}

handle_client :: (w: *Worker, c: *Connection, events: u32) {
    // 1. Output first. OUT also fires on registration and after every drain; with nothing
    //    queued it means nothing.
    if (events & EPOLLOUT) != 0 && c.pending.count > 0 {
        r := flush_pending(c);
        if r == .ERROR { close_connection(w, c); return; }
        c.last_activity_ms = now_ms();
        if r == .SENT && !resume_after_drain(w, c)  return;
    }

    // 2. Input next, so a request that arrived together with the peer's FIN is still answered.
    if (events & EPOLLIN) != 0 {
        if !read_and_dispatch(w, c)  return;
    }

    // 3. Hangups last. ERR/HUP: the socket is unusable. RDHUP: the peer half-closed its write
    //    side and can still read a pending response.
    if (events & (EPOLLERR | EPOLLHUP)) != 0 { close_connection(w, c); return; }
    if (events & EPOLLRDHUP) != 0 {
        if c.pending.count > 0  c.peer_closed = true;
        else                    close_connection(w, c);
    }
}

// The pending tail just drained. Close after a final (Connection: close) response; otherwise
// serve the requests the read buffer already holds, re-read a socket whose bytes arrived while
// the buffer was full (no new edge will announce them), and close once a peer that has finished
// sending holds every answer. Returns false when the connection was closed.
resume_after_drain :: (w: *Worker, c: *Connection) -> bool {
    if c.close_after_send { close_connection(w, c); return false; }
    if !dispatch_buffered(w, c)  return false;
    if c.read_stalled && c.pending.count == 0 {
        c.read_stalled = false;
        if !read_and_dispatch(w, c)  return false;
    }
    if c.peer_closed && c.pending.count == 0 { close_connection(w, c); return false; }
    return true;
}

// Read until EAGAIN (edge-triggered), dispatching complete requests as they land unless output
// is pending. Returns false when the connection was closed.
read_and_dispatch :: (w: *Worker, c: *Connection) -> bool {
    while true {
        available := READ_BUFFER_SIZE - c.bytes_used;
        if available <= 0 {
            if c.pending.count > 0 {
                // Pipelined requests are waiting behind a stalled response. The socket keeps the
                // rest; the drain re-reads it, since no new edge will announce bytes already there.
                c.read_stalled = true;
                return true;
            }
            // A full buffer with no complete request: the header block alone exceeds READ_BUFFER_SIZE.
            refuse_and_close(w, c, 431);
            return false;
        }

        n := read(c.fd, c.buf.data + c.bytes_used, xx available);
        if n < 0 {
            err := errno();
            if err == EAGAIN || err == EWOULDBLOCK  return true;
            if err == EINTR  continue;
            if err != ECONNRESET  Basic.log_error("read failed on fd %: errno %", c.fd, err);
            close_connection(w, c);
            return false;
        }
        if n == 0 {
            // EOF: answer whatever is complete, then close once any pending tail has gone.
            if !dispatch_buffered(w, c)  return false;
            if c.pending.count > 0 { c.peer_closed = true; return true; }
            close_connection(w, c);
            return false;
        }

        c.bytes_used += n;
        c.last_activity_ms = now_ms();
        if c.request_start_ms == 0  c.request_start_ms = c.last_activity_ms;
        if !dispatch_buffered(w, c)  return false;
    }
    return true;   // unreachable; `while true` alone does not satisfy the return-path check
}

// Parse and serve every complete request in the read buffer. Stops, without reading more, as
// soon as a response goes PENDING. Returns false when the connection was closed.
dispatch_buffered :: (w: *Worker, c: *Connection) -> bool {
    while c.pending.count == 0 {
        result := parse_request(c);
        if result == .INCOMPLETE  return true;
        if result == .ERROR {
            status: u16 = 400;
            if c.parse_error == .BODY_TOO_LARGE  status = 413;
            refuse_and_close(w, c, status);
            return false;
        }

        // COMPLETE. The request has fully arrived: no deadline bounds the handler.
        c.request_start_ms = 0;
        response: Response;
        wr: Write_Result;

        // Invoke the handler under the per-request pool allocator, with the handler's bound state
        // poked into the context. The core is routing-agnostic — for a routed server, w.handler is
        // router.jai's adapter. The response is written inside the same context so the header is
        // built from the Pool (never temporary storage), and any unsent tail is copied to the heap
        // before the Pool is reset below.
        new_ctx := context;
        new_ctx.allocator    = .{Pool_Module.pool_allocator_proc, *w.request_pool};
        new_ctx.handler_data = w.handler_data;
        push_context new_ctx {
            if w.handler  w.handler(*c.req, *response);
            wr = write_response(c, *c.req, *response, w.date);
        }
        Pool_Module.reset(*w.request_pool);   // recycle this request's Pool blocks (handler + header)
        c.last_activity_ms = now_ms();

        if wr == .ERROR { close_connection(w, c); return false; }
        keep_alive := c.req.keep_alive;
        reset_for_next_request(c);
        if wr == .PENDING {
            if !keep_alive  c.close_after_send = true;
            return true;    // dispatch resumes when EPOLLOUT drains the tail
        }
        if !keep_alive { close_connection(w, c); return false; }
    }
    return true;
}

// Answer a request the server will not serve with a canned status, then close.
refuse_and_close :: (w: *Worker, c: *Connection, status: u16) {
    Basic.log("fd %: refusing request with %", c.fd, status);
    send_canned(c.fd, status);
    // Closing with unread bytes in the receive queue makes the kernel reset the connection, and
    // the reset can destroy the reply before the client reads it. Half-close so the reply is
    // followed by a FIN, then discard what has already arrived. Bounded: a client still streaming
    // a large body can still see a reset; a full lingering close would need a timer state.
    shutdown(c.fd, .WR);
    discard: [4096] u8;
    for 1..16 {
        if read(c.fd, discard.data, discard.count) <= 0  break;
    }
    close_connection(w, c);
}

close_connection :: (w: *Worker, c: *Connection) {
    epoll_del_connection(*w.engine, c);
    close(c.fd);
    free_connection(*w.pool, c);
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
    last_sweep := now_ms();
    wait_ms: s32 = ifx TIMEOUTS_ENABLED then cast(s32) 1000 else cast(s32) -1;
    while w.running {
        nfds := epoll_process_events(*w.engine, timeout_ms = wait_ms);
        if nfds < 0 {
            err := errno();
            if err == EINTR continue;
            Basic.log_error("Worker %: epoll_wait failed: %", w.id, err);
            continue;
        }
        refresh_date(w);

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

        #if TIMEOUTS_ENABLED {
            now := now_ms();
            if now - last_sweep >= 1000 {
                check_timeouts(w, now);
                last_sweep = now;
            }
        }
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

#import "System";
