
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
    accept_paused: bool;             // accept4 ran out of fds/memory; the sweep retries
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
// cleared before dispatch. Sweeps run once a second from worker_run.

TIMEOUTS_ENABLED :: IDLE_TIMEOUT_MS > 0 || HEADER_TIMEOUT_MS > 0 || BODY_TIMEOUT_MS > 0 || WRITE_TIMEOUT_MS > 0 || LINGER_TIMEOUT_MS > 0 || MIN_SEND_RATE > 0;

Timeout_State :: enum u8 #specified {
    NONE   :: 0;
    IDLE   :: 1;   // between requests
    HEADER :: 2;   // request begun, headers incomplete
    BODY   :: 3;   // headers complete, body incomplete
    WRITE  :: 4;   // response tail pending
    LINGER :: 5;   // lingering close: final response sent, discarding input until EOF
    NEW    :: 6;   // accepted, no byte received yet: the first request's HEADER clock, from accept
}

timeout_state :: (c: *Connection) -> Timeout_State {
    if c.lingering                return .LINGER;
    if c.pending.count > 0        return .WRITE;
    if c.bytes_used == 0 {
        // accept_connections stamps request_start_ms; the read path only sets it when it is zero
        // and reset_for_next_request clears it, so this combination means nothing has arrived yet.
        if c.request_start_ms != 0  return .NEW;
        return .IDLE;
    }
    if c.parse_state == .BODY || c.parse_state == .CHUNKED  return .BODY;
    if c.parse_state == .COMPLETE return .NONE;   // never observed by the sweep; defensive
    return .HEADER;
}

// drain_deadline multiplies a tail's size by 1000, and arithmetic overflow is FATAL in every build.
#assert MAX_PENDING_BYTES <= 9000000000000 "MAX_PENDING_BYTES is too large for drain_deadline's arithmetic";

// When a tail of `bytes` queued at `now` must have drained to honor a minimum average rate after a
// grace period: now + grace_ms + bytes / rate (rate in bytes per second). 0 when rate <= 0: no
// floor. Takes its limits as arguments so tests can drive any value.
drain_deadline :: (now: s64, bytes: s64, grace_ms: s64, rate: s64) -> s64 {
    if rate <= 0  return 0;
    return now + grace_ms + bytes * 1000 / rate;
}

// A response tail was just queued: start the clocks the WRITE timeout and the rate floor read.
start_write_clock :: (c: *Connection, now: s64) {
    c.last_write_ms     = now;
    c.write_deadline_ms = drain_deadline(now, c.pending.count, WRITE_TIMEOUT_MS, MIN_SEND_RATE);
}

// The queued tail has missed its drain deadline, however steadily it has been moving.
write_too_slow :: inline (c: *Connection, now: s64) -> bool {
    return c.write_deadline_ms > 0 && now >= c.write_deadline_ms;
}

is_timed_out :: (c: *Connection, now: s64) -> (timed_out: bool, state: Timeout_State) {
    state := timeout_state(c);
    if state == .WRITE {
        // Two limits on a queued tail: a stall (no progress for WRITE_TIMEOUT_MS; input does not
        // count) and the rate floor (not drained by its deadline, however steadily it trickles).
        stalled := WRITE_TIMEOUT_MS > 0 && now - c.last_write_ms >= WRITE_TIMEOUT_MS;
        return stalled || write_too_slow(c, now), state;
    }
    limit: s64 = 0;
    since: s64 = 0;
    if state == {
        case .IDLE;   limit = IDLE_TIMEOUT_MS;   since = c.last_activity_ms;
        case .NEW;    limit = HEADER_TIMEOUT_MS; since = c.request_start_ms;   // from accept
        case .HEADER; limit = HEADER_TIMEOUT_MS; since = c.request_start_ms;
        case .BODY;   limit = BODY_TIMEOUT_MS;   since = c.request_start_ms;
        case .LINGER; limit = LINGER_TIMEOUT_MS; since = c.last_activity_ms;   // set on entering linger
        case;         return false, state;
    }
    if limit <= 0  return false, state;
    return now - since >= limit, state;
}

// Close every active connection whose timeout has passed. Returns how many were closed. A slow
// request gets a 408 through refuse_and_close (which logs it): the client may still be sending, so
// the reply needs the same drain-before-close to survive. Every other timeout closes silently.
check_timeouts :: (w: *Worker, now: s64) -> s32 {
    closed: s32 = 0;
    for * w.pool.connections {
        c := it;
        if c.state != .ACTIVE || c == w.listen_conn  continue;
        timed_out, state := is_timed_out(c, now);
        if !timed_out  continue;
        if state == .HEADER || state == .BODY {
            refuse_and_close(w, c, 408);
        } else {
            detail := ifx state == .WRITE && write_too_slow(c, now) then " (drained slower than MIN_SEND_RATE)" else "";
            Basic.log("fd %: % timeout%; closing", c.fd, state, detail);
            close_connection(w, c);
        }
        closed += 1;
    }
    return closed;
}

// The once-a-second work of worker_run: timeouts, retrying accepts paused by fd or memory
// exhaustion (an edge-triggered listen socket would not report the waiting backlog again), and the
// tail-refusal report.
worker_sweep :: (w: *Worker, now: s64) {
    #if TIMEOUTS_ENABLED  check_timeouts(w, now);
    if w.accept_paused  accept_connections(w);
    report_refused_tails(w);
}

// Tail refusals are a failure to serve, but a client can trigger one per request: one log_error
// line per worker per second with the counts, not one per refusal.
report_refused_tails :: (w: *Worker) {
    p := *w.pool;
    if p.refused_over_connection == 0 && p.refused_over_budget == 0  return;
    Basic.log_error("Worker %: closed % connection(s) whose response tail exceeded MAX_PENDING_BYTES (%) and % that would have exceeded MAX_PENDING_PER_WORKER (%) in the last second",
        w.id, p.refused_over_connection, MAX_PENDING_BYTES, p.refused_over_budget, MAX_PENDING_PER_WORKER);
    p.refused_over_connection = 0;
    p.refused_over_budget     = 0;
}

accept_connections :: (w: *Worker) {
    while true {
        addr: sockaddr_in;
        addrlen: u32 = size_of(sockaddr_in);
        conn_fd := accept4(w.listen_fd, cast(*sockaddr) *addr, xx *addrlen, .NONBLOCK | .CLOEXEC);

        if conn_fd < 0 {
            err := errno();
            if err == EAGAIN || err == EWOULDBLOCK { w.accept_paused = false; break; }   // backlog empty
            if err == EINTR  || err == ECONNABORTED  continue;  // retry; the aborted one is gone
            if err == EMFILE || err == ENFILE || err == ENOBUFS || err == ENOMEM {
                // Out of descriptors or memory. The rest of the backlog waits in the kernel, and an
                // edge-triggered listen socket reports it again only when another connection
                // arrives: pause, and let the once-a-second sweep retry. Logged once per pause.
                if !w.accept_paused  Basic.log_error("Worker %: accept4 failed (errno %); pausing accepts, retrying every second", w.id, err);
                w.accept_paused = true;
                break;
            }
            Basic.log_error("Worker %: accept4 failed: errno %", w.id, err);
            break;
        }
        if w.accept_paused {
            Basic.log("Worker %: accepting again", w.id);
            w.accept_paused = false;
        }

        // Disable Nagle's algorithm — send response bytes immediately
        nodelay: s32 = 1;
        setsockopt(conn_fd, xx IPPROTO.TCP, TCP_NODELAY, xx *nodelay, size_of(type_of(nodelay)));

        c := get_connection(*w.pool);
        if c == null {
            Basic.log_error("Worker %: connection pool exhausted; dropping fd %", w.id, conn_fd);
            close(conn_fd);
            continue;
        }
        c.fd = conn_fd;
        c.last_activity_ms = now_ms();
        c.request_start_ms = c.last_activity_ms;   // NEW: the first request is timed from accept, as nginx does

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
    // A lingering close only discards input until the peer's EOF (or the LINGER timeout).
    if c.lingering {
        if (events & (EPOLLERR | EPOLLHUP)) != 0 { close_connection(w, c); return; }
        if (events & (EPOLLIN | EPOLLRDHUP)) != 0 && !discard_input(c)  close_connection(w, c);
        return;
    }

    // 1. Output first. OUT also fires on registration and after every drain; with nothing
    //    queued it means nothing.
    if (events & EPOLLOUT) != 0 && c.pending.count > 0 {
        offset_before := c.pending_offset;
        r := flush_pending(c);
        if r == .ERROR { close_connection(w, c); return; }
        if r == .SENT || c.pending_offset > offset_before {   // progress (SENT resets the offset)
            now := now_ms();
            c.last_activity_ms = now;
            c.last_write_ms    = now;
        }
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
    if c.close_after_send { linger_close(w, c); return false; }
    // A partial next request is timed from the drain, not from when its bytes arrived: while
    // output was pending the server was the bottleneck (its read may even have been stalled).
    if c.request_start_ms != 0  c.request_start_ms = c.last_activity_ms;
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
            // A full buffer with no complete request: the request line (414), the header block
            // (431) or a chunked body (413) alone exceeds READ_BUFFER_SIZE.
            status: u16 = 431;
            if c.parse_state == .REQUEST_LINE  status = 414;
            if c.parse_state == .CHUNKED       status = 413;
            refuse_and_close(w, c, status);
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
            refuse_and_close(w, c, parse_error_status(c.parse_error));
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
        now := now_ms();
        c.last_activity_ms = now;
        if wr == .ERROR { close_connection(w, c); return false; }
        if wr == .PENDING  start_write_clock(c, now);   // the WRITE and drain-rate clocks
        keep_alive := c.req.keep_alive;
        reset_for_next_request(c);
        if wr == .PENDING {
            if !keep_alive  c.close_after_send = true;
            return true;    // dispatch resumes when EPOLLOUT drains the tail
        }
        if !keep_alive { linger_close(w, c); return false; }
    }
    return true;
}

// Answer a request the server will not serve with a canned status, then close. Under backpressure
// the reply is queued and the close waits for EPOLLOUT to drain it.
refuse_and_close :: (w: *Worker, c: *Connection, status: u16) {
    Basic.log("fd %: refusing request with %", c.fd, status);
    r := write_or_queue(c, canned_response(status, w.date));
    if r == .ERROR { close_connection(w, c); return; }
    if r == .PENDING {
        c.close_after_send = true;
        start_write_clock(c, now_ms());
        return;
    }
    linger_close(w, c);
}

// Read and drop the input that has arrived. Returns false once the peer has finished sending
// (EOF) or the socket failed; true while more may come. Bounded per call: edge-triggered epoll
// reports any further arrival again.
discard_input :: (c: *Connection) -> bool {
    discard: [4096] u8;
    for 1..64 {
        n := read(c.fd, discard.data, discard.count);
        if n > 0  continue;
        if n == 0  return false;
        err := errno();
        if err == EINTR  continue;
        return err == EAGAIN || err == EWOULDBLOCK;
    }
    return true;
}

// Close after a final response without risking a reset. Closing with unread input makes TCP send
// RST, and the kernel then discards response bytes it has not transmitted yet. Half-close so the
// response is followed by a FIN, then keep discarding input until the peer's EOF; a peer that
// never finishes is closed by the LINGER timeout. LINGER_TIMEOUT_MS = 0 closes after one drain.
linger_close :: (w: *Worker, c: *Connection) {
    shutdown(c.fd, .WR);
    if !discard_input(c) { close_connection(w, c); return; }
    #if LINGER_TIMEOUT_MS > 0 {
        c.lingering        = true;
        c.last_activity_ms = now_ms();   // the LINGER clock
    } else {
        close_connection(w, c);
    }
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
    while w.running {
        // Wake at least once a second, whatever is enabled, so the sweep always runs: a refusal
        // count must never be stranded. A 1 Hz wakeup per worker costs nothing measurable.
        nfds := epoll_process_events(*w.engine, timeout_ms = 1000);
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

        now := now_ms();
        if now - last_sweep >= 1000 {
            worker_sweep(w, now);
            last_sweep = now;
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
