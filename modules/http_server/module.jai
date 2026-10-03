// Every parameter is in the program-wide group 2; group 1 (per-import) is deliberately empty.
// Group-2 parameters are set once, by the main program, and every importer inherits them,
// including http_router's bare `#import "http_server"`. Group-1 values set in main would NOT
// reach that import: a library's bare import is a second, default instantiation of this module,
// whose Request/Response types do not unify with main's, so the program fails to compile. A
// "build global" is the simple answer for now; passing the http_server module instance to
// http_router as a module parameter is the per-instance alternative (CLAUDE.md, Future
// Considerations). Override from main, e.g.:
//     #import "http_server"()(Handler_Data = http_router.Router, MAX_PENDING_BYTES = 16777216);
#module_parameters ()(
    // Type of the per-request bound state handed to handlers via `context.handler_data`.
    // Default `void` => `*void` (fully generic). A consumer can inject a concrete type for
    // cast-free, type-safe handler state. There is one Context type per program, so the type
    // of the `#add_context handler_data` field cannot vary per-import.
    Handler_Data        : Type = void,
    READ_BUFFER_SIZE    : s32 = 4096,
    MAX_HEADERS         : s32 = 64,
    MAX_FORM_VALUES     : s32 = 64,
    MAX_MULTIPART_PARTS : s32 = 16,
    LISTEN_BACKLOG      : s32 = 1024,
    // Cap on unsent response bytes one connection may queue when its socket is full. A tail that
    // would exceed it closes the connection (log_error). Only slow readers ever hold a tail. Unlike
    // the timeouts, 0 does not disable it: 0 means no tail may be queued, so every stalled
    // response closes its connection.
    MAX_PENDING_BYTES   : s64 = 1048576,
    // Cap on the response tail bytes all of one worker's connections may queue together. A tail
    // that would push the worker past it closes its connection, as MAX_PENDING_BYTES does. Without
    // it every pool slot could hold MAX_PENDING_BYTES (16 workers x 1024 slots x 1 MB = 16 GB). Like
    // MAX_PENDING_BYTES, 0 is literal: no tail may be queued.
    MAX_PENDING_PER_WORKER : s64 = 67108864,
    // Timeouts in milliseconds; 0 disables each. See docs/plans/2026-10-03-fib-lifts-design.md §5.
    IDLE_TIMEOUT_MS     : s64 = 60000,    // kept-alive connection between requests
    HEADER_TIMEOUT_MS   : s64 = 10000,    // from a request's first byte until its headers are complete
    BODY_TIMEOUT_MS     : s64 = 30000,    // from a request's first byte until its body is complete
    // A queued response making no progress toward the peer: neither our tail nor the bytes the
    // kernel holds for the peer (TIOCOUTQ) shrank. Also the grace before MIN_SEND_RATE applies, so
    // 0 here makes the floor apply from the first sweep.
    WRITE_TIMEOUT_MS    : s64 = 30000,
    // Minimum average rate, in bytes per second, at which the peer must take a queued response
    // once the WRITE_TIMEOUT_MS grace has passed, counted from when the tail was queued and
    // including the bytes the kernel already held. A reader at or above it is never cut; one below
    // it frees its slot and tail. The WRITE timeout alone only catches a stall. 0: no floor.
    MIN_SEND_RATE       : s64 = 16384,
    // Lingering close: after a final response the server half-closes and discards input until the
    // peer's EOF, for at most this long, so a close never turns into a reset that destroys the
    // response. 0 closes right after one drain.
    LINGER_TIMEOUT_MS   : s64 = 5000
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
