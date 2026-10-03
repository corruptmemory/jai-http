#module_parameters (
    CACHE_LINE_SIZE     : s32 = 64,
    READ_BUFFER_SIZE    : s32 = 4096,
    MAX_HEADERS         : s32 = 64,
    MAX_FORM_VALUES     : s32 = 64,
    MAX_MULTIPART_PARTS : s32 = 16,
    LISTEN_BACKLOG      : s32 = 1024
)(
    // Program-wide (set-once) parameters. Only the main program can set them, and every other
    // importer inherits them, including http_router's bare `#import "http_server"`. Group-1 values
    // set in main would NOT reach that import: a library's bare import is a second, default
    // instantiation of this module, whose Request/Response types do not unify with main's, so the
    // program fails to compile. Tunables a routed program must be able to set therefore live here.
    // Override from main, e.g.:
    //     #import "http_server"()(Handler_Data = http_router.Router, MAX_PENDING_BYTES = 16777216);

    // Type of the per-request bound state handed to handlers via `context.handler_data`.
    // Default `void` => `*void` (fully generic). A consumer can inject a concrete type for
    // cast-free, type-safe handler state. There is one Context type per program, so the type
    // of the `#add_context handler_data` field cannot vary per-import.
    Handler_Data      : Type = void,
    // Cap on unsent response bytes one connection may queue when its socket is full. A tail that
    // would exceed it closes the connection (logged). Only slow readers ever hold a tail.
    MAX_PENDING_BYTES : s64 = 1048576,
    // Timeouts in milliseconds; 0 disables each. See docs/plans/2026-10-03-fib-lifts-design.md §5.
    IDLE_TIMEOUT_MS   : s64 = 60000,    // kept-alive connection between requests
    HEADER_TIMEOUT_MS : s64 = 10000,    // from a request's first byte until its headers are complete
    BODY_TIMEOUT_MS   : s64 = 30000,    // from a request's first byte until its body is complete
    WRITE_TIMEOUT_MS  : s64 = 30000     // a pending response making no progress toward the peer
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
