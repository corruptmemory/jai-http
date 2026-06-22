
// http_router — chi-style routing layered on the routing-agnostic `http_server` core.
//
// This is the GetRect↔Simp split applied to our HTTP stack: `http_server` is the valuable,
// reusable machinery (accept, epoll, zero-copy parse, keep-alive, writev, per-request Pool) and
// knows NOTHING about routing; routing is an OPTIONAL module built on top. The core invokes a
// bare `Handler` (req, resp); this module supplies one such handler (`route_handler`) that runs
// the router's dispatch, and wires it in via the core's `serve`.
//
// Routing limits are this module's own parameters (they describe the router, not the core).

#module_parameters (
    MAX_ROUTES        : s32 = 128,
    MAX_PARAMS        : s32 = 8,
    MAX_MIDDLEWARE    : s32 = 16,
    MAX_MOUNTS        : s32 = 16,
    MAX_PATH_SEGMENTS : s32 = 32
);

#scope_module

Basic    :: #import "Basic";
Compiler :: #import "Compiler";   // compile-time only: friendly error in route_handler when the core isn't wired

// The core. Bare import — it INHERITS the program-wide Handler_Data. This module's dispatch
// adapter (router.jai) is cast-free, which requires context.handler_data to be typed *Router; i.e.
// the consuming MAIN PROGRAM must import the core with `Handler_Data = Router`. (Program parameters
// can only be supplied from the main program, never from a library module — so this import cannot
// set it here.) A main that omits it gets a clear *void-vs-*Router type error, not silent breakage.
#import "http_server";

#load "trie.jai";
#load "router.jai";
