
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
    req:          Request;
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
        pool.free_list = c;
        i -= 1;
    }
    pool.free_count = count;
}

destroy_pool :: (pool: *Connection_Pool) {
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
    c.parse_state = .REQUEST_LINE;
    c.req.header_count = 0;
    c.req.keep_alive = false;

    return c;
}

// Push a connection back onto the free list.
free_connection :: (pool: *Connection_Pool, c: *Connection) {
    Basic.assert(c != null, "Cannot free null connection");
    c.fd = -1;
    c.state = .FREE;
    c.next_free = pool.free_list;
    pool.free_list = c;
    pool.free_count += 1;
}
