
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
    MAX_ROUTES     : s32 = 128,
    MAX_PARAMS     : s32 = 8,
    MAX_MIDDLEWARE : s32 = 16,
    MAX_MOUNTS     : s32 = 16
);

#scope_module

Basic :: #import "Basic";

// The core. Imported with the DEFAULT program parameter (Handler_Data = void), so
// context.handler_data is *void here and route_handler casts it back to *Router. Eliminating
// that single cast — by importing the core with Handler_Data = Router — is the committed next
// step (see docs/plans/2026-06-19-handler-context-refactor-design.md). Not re-exported: a
// consumer imports `http_server` directly alongside this module (dual import).
#import "http_server";

#load "router.jai";
