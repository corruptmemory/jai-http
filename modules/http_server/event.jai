
MAX_EVENTS :: 1024;

Event_Engine :: struct {
    epoll_fd: s32 = -1;
    events:   [MAX_EVENTS] epoll_event;
}

init_event_engine :: (engine: *Event_Engine) -> bool {
    engine.epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if engine.epoll_fd == -1 {
        Basic.log_error("epoll_create1 failed: %", errno());
        return false;
    }
    return true;
}

destroy_event_engine :: (engine: *Event_Engine) {
    if engine.epoll_fd != -1 {
        close(engine.epoll_fd);
        engine.epoll_fd = -1;
    }
}

// Encode a connection pointer + instance bit into epoll_data.ptr.
// Instance bit is packed into the LSB (connection pointers are at least 2-byte aligned).
encode_connection_ptr :: (c: *Connection) -> *void {
    val := cast(u64) c;
    val |= cast(u64) c.instance;
    return cast(*void) val;
}

// Decode epoll_data.ptr back to connection pointer + instance bit.
decode_connection_ptr :: (ptr: *void) -> (connection: *Connection, instance: u8) {
    val := cast(u64) ptr;
    instance := cast(u8)(val & 1);
    connection := cast(*Connection)(val & ~cast(u64)1);
    return connection, instance;
}

// Add a connection to epoll with specified event flags.
epoll_add_connection :: (engine: *Event_Engine, c: *Connection, events: u32) -> bool {
    ev := epoll_event.{
        events = events,
    };
    ev.data.ptr = encode_connection_ptr(c);
    if epoll_ctl(engine.epoll_fd, .ADD, c.fd, *ev) < 0 {
        Basic.log_error("epoll_ctl ADD failed for fd %: %", c.fd, errno());
        return false;
    }
    return true;
}

// Remove a connection from epoll.
epoll_del_connection :: (engine: *Event_Engine, c: *Connection) -> bool {
    if epoll_ctl(engine.epoll_fd, .DEL, c.fd, null) < 0 {
        Basic.log_error("epoll_ctl DEL failed for fd %: %", c.fd, errno());
        return false;
    }
    return true;
}

// Wait for events. Returns the number of ready events.
epoll_process_events :: (engine: *Event_Engine, timeout_ms: s32 = -1) -> s32 {
    return epoll_wait(engine.epoll_fd, engine.events.data, MAX_EVENTS, timeout_ms);
}

// Check if an event is stale (connection was recycled since the event was registered).
is_stale_event :: (ptr: *void, c: *Connection) -> bool {
    _, event_instance := decode_connection_ptr(ptr);
    return event_instance != c.instance;
}
