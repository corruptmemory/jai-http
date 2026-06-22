
// -- Per-request context, added to Jai's implicit context --

#add_context http: *HTTP_Context;

Param :: struct {
    name:  string;   // View into route pattern (compile-time constant)
    value: string;   // View into connection read buffer (zero-copy)
}

HTTP_Context :: struct {
    req:         *Request;
    resp:        *Response;
    params:      [MAX_PARAMS] Param;
    param_count: s32;
    // Middleware chain state
    middleware:  [] Middleware;
    mw_index:    s32;
    handler:     Route_Handler;
}

// -- Handler types --

Route_Handler :: #type (req: *Request, resp: *Response);
Middleware     :: #type (ctx: *HTTP_Context);

// -- Route and Router types --

Mount_Point :: struct {
    prefix: string;
    router: *Router;
}

Router :: struct {
    tree:        Trie;
    middleware:  [MAX_MIDDLEWARE] Middleware;
    mw_count:    s32;
    mounts:      [MAX_MOUNTS] Mount_Point;
    mount_count: s32;
}

// -- Route registration --

get :: (router: *Router, pattern: string, handler: Route_Handler) {
    route(router, "GET", pattern, handler);
}

post :: (router: *Router, pattern: string, handler: Route_Handler) {
    route(router, "POST", pattern, handler);
}

put :: (router: *Router, pattern: string, handler: Route_Handler) {
    route(router, "PUT", pattern, handler);
}

http_delete :: (router: *Router, pattern: string, handler: Route_Handler) {
    route(router, "DELETE", pattern, handler);
}

route :: (router: *Router, method: string, pattern: string, handler: Route_Handler) {
    partial, ok := build_partial_tree(method, pattern, handler);
    if !ok  return;   // build_partial_tree already logged the malformed pattern
    if !merge(*router.tree, partial) {
        Basic.log_error("http_router: route registration conflict for % %", method, pattern);
    }
}

// -- Middleware --

use :: (router: *Router, mw: Middleware) {
    if router.mw_count >= MAX_MIDDLEWARE return;
    router.middleware[router.mw_count] = mw;
    router.mw_count += 1;
}

// -- Sub-router mounting --

mount :: (router: *Router, prefix: string, sub: *Router) {
    if router.mount_count >= MAX_MOUNTS return;
    router.mounts[router.mount_count] = .{ prefix = prefix, router = sub };
    router.mount_count += 1;
}

// -- Middleware chain walking --

proceed :: (ctx: *HTTP_Context) {
    if ctx.mw_index < ctx.middleware.count {
        mw := ctx.middleware[ctx.mw_index];
        ctx.mw_index += 1;
        mw(ctx);
    } else {
        ctx.handler(ctx.req, ctx.resp);
    }
}

// -- Path parameter access (reads from context.http) --

param :: (name: string) -> (value: string, found: bool) {
    ctx := context.http;
    if ctx == null {
        result: string;
        return result, false;
    }
    for i: 0..cast(s64) ctx.param_count - 1 {
        if string_equals(ctx.params[i].name, name) {
            return ctx.params[i].value, true;
        }
    }
    result: string;
    return result, false;
}

// -- Dispatch (called by server event loop) --

dispatch :: (router: *Router, req: *Request, resp: *Response) {
    // Mounts first — if the path starts with a mount prefix, delegate to the sub-router.
    for i: 0..cast(s64) router.mount_count - 1 {
        mp := *router.mounts[i];
        if starts_with(req.path, mp.prefix) {
            original_path := req.path;
            remaining := req.path;
            remaining.data  += mp.prefix.count;
            remaining.count -= mp.prefix.count;
            if remaining.count == 0  req.path = "/";
            else                     req.path = remaining;
            dispatch_with_middleware(router, mp.router, req, resp);
            req.path = original_path;
            return;
        }
    }

    http_ctx: HTTP_Context;
    handler, status := tree_match(*router.tree, req.method, req.path, *http_ctx.params, *http_ctx.param_count);

    if status == .MATCHED {
        http_ctx.req     = req;
        http_ctx.resp    = resp;
        http_ctx.handler = handler;

        mw_slice: [] Middleware;
        mw_slice.data  = router.middleware.data;
        mw_slice.count = cast(s64) router.mw_count;
        http_ctx.middleware = mw_slice;
        http_ctx.mw_index   = 0;

        ctx := *context;
        ctx.http = *http_ctx;
        push_context ctx.* {
            proceed(*http_ctx);
        }
        return;
    }

    if status == .METHOD_NOT_ALLOWED {
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
        return;
    }

    resp.status_code = 404;
    resp.body = "Not Found";
}

// -- Routing as an OPTIONAL Handler layered on the core --
//
// The http_server core knows nothing about routing; it just invokes a bare Handler. This adapter
// bridges that generic contract to dispatch(), cast-free: context.handler_data is statically typed
// *Router because the consuming MAIN PROGRAM imports the core with Handler_Data = Router.
//
// That wiring is the consumer's job, explicitly (program parameters can only be supplied from the
// main program — a library cannot do it, and shouldn't: pulling in this optional dependency means
// you opt into the wiring). If main omits it, the #assert below fails LOUD and tells you exactly
// what to add — no silent fallback, no magic.
route_handler :: (req: *Request, resp: *Response) {
    // #run forces compile-time evaluation so the result is a constant #if can branch on.
    ROUTER_COMPATIBLE :: #run handler_data_is_router(type_of(context.handler_data));
    #if ROUTER_COMPATIBLE {
        // Cast-free: context.handler_data is *Router, OR a *T whose T embeds Router via `#as using`
        // (so the *T -> *Router conversion happens implicitly at the dispatch call below).
        dispatch(context.handler_data, req, resp);
    } else {
        // Not a silent fallback — a hard compile error. compiler_report owns the entire message
        // text (no compiler-generated prefix), so the consumer gets a clean, actionable diagnostic.
        #run Compiler.compiler_report(#string MSG
http_router is a cast-free routing layer: the core's per-request handler-state slot (Handler_Data)
must be Router, OR a struct that embeds Router via `#as using` (so *Handler_Data converts to *Router).
Only the MAIN PROGRAM can set Handler_Data — program parameters may be supplied solely from main,
never from a library module (which is why this module can't wire itself).

Fix: in your main program, import the core with a Router-compatible Handler_Data, e.g.

    // simplest — the router itself is the handler state:
    #import "http_server"()(Handler_Data = http_router.Router);

    // or your own app-state that IS-A Router (handlers then read full app state, still cast-free):
    //     App :: struct { #as using router: http_router.Router;  /* ...app fields... */ }
    #import "http_server"()(Handler_Data = App);

    http_router :: #import "http_router";
MSG
        );
    }
}

// serve(*Server, *T/Router): install the router as the server's handler. T is Router, or your own
// app-state struct that embeds Router via `#as using` — i.e. exactly the type the main program set
// as Handler_Data. We pass *T STRAIGHT THROUGH as the core's bound state (no downcast to *Router),
// so the core stores the full *T and handlers later read context.handler_data as *T. Resolves to the
// core's serve(*Server, Handler, *Handler_Data). Namespace this import (e.g. http_router :: #import
// "http_router") so it never collides with the core's serve.
serve :: (server: *Server, router: *$T/Router) {
    serve(server, route_handler, router);
}

// -- Pattern matching (public for testing) --

// Segment-by-segment pattern matching.
// Literal segments must match exactly. `:name` segments match any non-empty segment and capture into params.
// `*name` segments match the rest of the path (greedy) and capture into params. Must be the last segment.
match_pattern :: (pattern: string, path: string, params: *[MAX_PARAMS] Param, param_count: *s32) -> bool {
    pi := 0;   // pattern index
    ai := 0;   // path (actual) index

    while pi < pattern.count && ai < path.count {
        // Both should be at a '/' here
        if pattern[pi] != #char "/" || path[ai] != #char "/" return false;

        // Skip the '/'
        pi += 1;
        ai += 1;

        // Find end of pattern segment
        ps := pi;
        while pi < pattern.count && pattern[pi] != #char "/" {
            pi += 1;
        }

        pat_seg_start := ps;
        pat_seg_end   := pi;
        pat_seg_len   := pat_seg_end - pat_seg_start;

        // Wildcard segment — matches everything remaining in the path
        if pat_seg_len > 0 && pattern[pat_seg_start] == #char "*" {
            // Must have at least one character remaining in path
            if ai >= path.count return false;

            if param_count.* < MAX_PARAMS {
                // Name is everything after the '*'; value is the rest of the path.
                params.*[param_count.*] = .{
                    name  = substr(pattern, pat_seg_start + 1, pat_seg_len - 1),
                    value = substr(path, ai, path.count - ai),
                };
                param_count.* += 1;
            }
            return true;  // Wildcard consumes the rest — always a match
        }

        // Find end of path segment
        as := ai;
        while ai < path.count && path[ai] != #char "/" {
            ai += 1;
        }

        path_seg_start := as;
        path_seg_end   := ai;
        path_seg_len   := path_seg_end - path_seg_start;

        if pat_seg_len > 0 && pattern[pat_seg_start] == #char ":" {
            // Param segment — must match at least one character
            if path_seg_len == 0 return false;

            if param_count.* < MAX_PARAMS {
                // Name is everything after the ':'; value is the path segment.
                params.*[param_count.*] = .{
                    name  = substr(pattern, pat_seg_start + 1, pat_seg_len - 1),
                    value = substr(path, path_seg_start, path_seg_len),
                };
                param_count.* += 1;
            }
        } else {
            // Literal segment — must match exactly
            if pat_seg_len != path_seg_len return false;
            for k: 0..pat_seg_len - 1 {
                if pattern[pat_seg_start + k] != path[path_seg_start + k] return false;
            }
        }
    }

    // Both must be fully consumed
    return pi == pattern.count && ai == path.count;
}

// -- Private helpers --

#scope_file

// Compile-time: is *Handler_Data assignable to *Router? (handler_data_ptr_type is type_of(context.handler_data),
// i.e. the *Handler_Data pointer type.) True when Handler_Data is Router, or a struct that embeds Router via
// `#as using` — which is precisely the relation that makes *Handler_Data implicitly convert to *Router, so the
// cast-free dispatch(context.handler_data, ...) call typechecks. A plain `using` (no #as) only promotes field
// access and does NOT make the pointer convertible, so we test the AS flag specifically. Recurses for multi-level.
handler_data_is_router :: (handler_data_ptr_type: Type) -> bool {
    info := cast(*Type_Info) handler_data_ptr_type;
    if info.type != .POINTER  return false;
    return is_router_base((cast(*Type_Info_Pointer) info).pointer_to);
}

is_router_base :: (t: *Type_Info) -> bool {
    if t == type_info(Router)  return true;
    if t.type != .STRUCT       return false;
    s := cast(*Type_Info_Struct) t;
    for s.members {
        if !(it.flags & .AS)  continue;          // only #as members grant the implicit *T -> *base conversion
        if is_router_base(it.type)  return true;
    }
    return false;
}

// Dispatch into a sub-router, running parent middleware first, then sub-router middleware.
dispatch_with_middleware :: (parent: *Router, sub: *Router, req: *Request, resp: *Response) {
    http_ctx: HTTP_Context;
    handler, status := tree_match(*sub.tree, req.method, req.path, *http_ctx.params, *http_ctx.param_count);

    if status == .MATCHED {
        http_ctx.req     = req;
        http_ctx.resp    = resp;
        http_ctx.handler = handler;

        // Merge middleware: parent first, then sub-router. Temp storage for the merged slice.
        total_mw := cast(s64) parent.mw_count + cast(s64) sub.mw_count;
        if total_mw > 0 {
            merged := Basic.NewArray(total_mw, Middleware, initialized = false,, allocator = Basic.temp);
            for j: 0..cast(s64) parent.mw_count - 1  merged[j] = parent.middleware[j];
            for j: 0..cast(s64) sub.mw_count - 1     merged[cast(s64) parent.mw_count + j] = sub.middleware[j];
            http_ctx.middleware = merged;
        }
        http_ctx.mw_index = 0;

        ctx := *context;
        ctx.http = *http_ctx;
        push_context ctx.* {
            proceed(*http_ctx);
        }
        return;
    }

    if status == .METHOD_NOT_ALLOWED {
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
        return;
    }

    resp.status_code = 404;
    resp.body = "Not Found";
}

starts_with :: inline (s: string, prefix: string) -> bool {
    if s.count < prefix.count return false;
    for i: 0..prefix.count - 1 {
        if s[i] != prefix[i] return false;
    }
    return true;
}
