
type Connection_Flags :: enum_flags u32 {
    READ;
    WRITE;
    ACTIVE;
    DISABLED;
    READING;
    WRITING;
    READY;
    ONE_SHOT;
    COMPLETE;
    TIMED_OUT;
    TIMER_SET;
    DELAYED;
    DEFERRED_ACCEPT;
    PENDING_EOF;
    POSTED;
    CLOSED;
    EOF   :: 1 << 30;
    ERROR :: 1 << 31;
}

Connection :: struct {
    flags:        Connection_Flags;
    socket:       Socket;
    remote:       sockaddr_in;
}

type 
