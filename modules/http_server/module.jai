
#module_parameters (
    CACHE_LINE_SIZE     : s32 = 64,
    READ_BUFFER_SIZE    : s32 = 4096,
    MAX_HEADERS         : s32 = 64,
    MAX_FORM_VALUES     : s32 = 64,
    MAX_MULTIPART_PARTS : s32 = 16,
    LISTEN_BACKLOG      : s32 = 1024,
    // Cap on unsent response bytes one connection may queue when its socket is full. A tail that
    // would exceed it closes the connection (logged). Only slow readers ever hold a tail.
    MAX_PENDING_BYTES   : s64 = 1048576,
    // Timeouts in milliseconds; 0 disables each. See docs/plans/2026-10-03-fib-lifts-design.md §5.
    IDLE_TIMEOUT_MS     : s64 = 60000,    // kept-alive connection between requests
    HEADER_TIMEOUT_MS   : s64 = 10000,    // from a request's first byte until its headers are complete
    BODY_TIMEOUT_MS     : s64 = 30000,    // from a request's first byte until its body is complete
    WRITE_TIMEOUT_MS    : s64 = 30000     // a pending response making no progress toward the peer
)(
    // Program-wide (set-once) type of the per-request bound state handed to handlers via
    // `context.handler_data`. Default `void` => `*void` (fully generic). A consumer can
    // inject a concrete type for cast-free, type-safe handler state. Must live in this
    // second (program) group: there is one Context type per program, so the type of the
    // `#add_context handler_data` field cannot vary per-import.
    Handler_Data : Type = void
);

#scope_module
Basic :: #import "Basic";
Pool_Module :: #import "Pool";

#import "POSIX";
#import "Linux";
#import "Socket";
#import "Thread";

#load "http.jai";
#load "connection.jai";
#load "event.jai";
#load "helpers.jai";
#load "server.jai";
