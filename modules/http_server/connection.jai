
Connection_State :: enum u8 #specified {
    FREE   :: 0;
    ACTIVE :: 1;
}

Connection :: struct {
    state:        Connection_State;
    fd:           s32 = -1;
    instance:     u8;
    next_free:    *Connection;      // Valid when state == .FREE

    // Per-connection read buffer and incremental parser state
    buf:          [READ_BUFFER_SIZE] u8;
    bytes_used:   s64;
    parse_offset: s64;
    parse_state:  Parse_State;
    parse_error:  Parse_Error;      // Why parse_request returned .ERROR
    req:          Request;

    // Chunked body decoding (parse_chunked). The decoded body is buf[body_start .. body_end);
    // body_end trails parse_offset, because decoding only ever removes framing bytes.
    chunk_phase:     Chunk_Phase;
    chunk_remaining: s64;          // bytes of the current chunk's data not yet consumed
    body_start:      s64;
    body_end:        s64;

    // Send path, slow path only. `pending` holds response bytes the kernel did not take. Its
    // allocator is pinned to the heap in init_pool: the request Pool and temporary storage are
    // both reset underneath a stalled response, so neither may back this buffer.
    pending:          [..] u8;
    pending_offset:   s64;      // bytes of `pending` already handed to the kernel
    close_after_send: bool;     // close once `pending` drains
    read_stalled:     bool;     // read buffer filled while output was pending; re-read after drain
    peer_closed:      bool;     // the peer finished sending (EOF / RDHUP); close once every answer drains
    lingering:        bool;     // final response sent and write side shut; discarding input until EOF

    // Timeouts: monotonic milliseconds from now_ms() in server.jai
    last_activity_ms: s64;      // accept, or the last successful read / write progress
    last_write_ms:    s64;      // start of a stalled write, or its last progress; the WRITE timeout's clock
    request_start_ms: s64;      // first byte of the request being parsed; 0 while idle or dispatching
}

Connection_Pool :: struct {
    connections:  [] Connection;
    free_list:    *Connection;    // Head of singly-linked free list
    free_count:   s64;
    total:        s64;
    data_to_free: *void;
}

init_pool :: (pool: *Connection_Pool, count: s64) {
    Basic.assert(count > 0, "Connection pool size must be > 0");
    pool.connections, pool.data_to_free = Basic.NewArray(count, Connection, true);
    pool.total = count;

    // Build free list: push in reverse so index 0 is at the head
    pool.free_list = null;
    i := count - 1;
    while i >= 0 {
        c := *pool.connections[i];
        c.state = .FREE;
        c.next_free = pool.free_list;
        c.fd = -1;
        c.instance = 0;
        // Pin the slow-path buffer to whatever allocator is current at init (the heap). Dispatch
        // runs under the per-request Pool, which must never back bytes that outlive a request.
        c.pending.allocator = context.allocator;
        pool.free_list = c;
        i -= 1;
    }
    pool.free_count = count;
}

destroy_pool :: (pool: *Connection_Pool) {
    for * pool.connections  release_pending(it);
    if pool.data_to_free {
        Basic.free(pool.data_to_free);
        pool.data_to_free = null;
    }
    pool.free_list = null;
    pool.free_count = 0;
    pool.total = 0;
}

// Pop a connection from the free list, mark it ACTIVE, flip instance bit.
get_connection :: (pool: *Connection_Pool) -> *Connection {
    c := pool.free_list;
    if c == null return null;

    pool.free_list = c.next_free;
    pool.free_count -= 1;

    c.state = .ACTIVE;
    c.instance ^= 1;
    c.bytes_used = 0;
    c.parse_offset = 0;
    reset_parse(c);

    release_pending(c);
    c.close_after_send = false;
    c.read_stalled     = false;
    c.peer_closed      = false;
    c.lingering        = false;
    c.last_activity_ms = 0;
    c.last_write_ms    = 0;
    c.request_start_ms = 0;

    return c;
}

// Push a connection back onto the free list.
free_connection :: (pool: *Connection_Pool, c: *Connection) {
    Basic.assert(c != null, "Cannot free null connection");
    release_pending(c);
    c.fd = -1;
    c.state = .FREE;
    c.next_free = pool.free_list;
    pool.free_list = c;
    pool.free_count += 1;
}

// Free the queued tail and reset the cursor. array_reset frees through the array's own (pinned)
// allocator and keeps it set. Guarded on data: Basic.free calls the allocator proc
// unconditionally, so an empty array on a slot that was never pinned must not reach it. Idempotent.
release_pending :: (c: *Connection) {
    if c.pending.data  Basic.array_reset(*c.pending);
    c.pending_offset = 0;
}

// Append raw bytes to a resizable byte array using the array's own allocator. Grows by doubling:
// array_reserve allocates exactly what it is asked for, so repeated appends would be quadratic.
append_bytes :: (arr: *[..] u8, data: *u8, count: s64) {
    if count <= 0  return;
    needed := arr.count + count;
    if needed > arr.allocated  Basic.array_reserve(arr, ifx needed > 2 * arr.allocated then needed else 2 * arr.allocated);
    memcpy(arr.data + arr.count, data, count);
    arr.count += count;
}
