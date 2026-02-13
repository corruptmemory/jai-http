
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

Route :: struct {
    method:  string;         // "GET", "POST", etc. Empty = any method.
    pattern: string;         // e.g. "/users/:id"
    handler: Route_Handler;
}

Mount_Point :: struct {
    prefix: string;
    router: *Router;
}

Router :: struct {
    routes:      [MAX_ROUTES] Route;
    route_count: s32;
    middleware:   [MAX_MIDDLEWARE] Middleware;
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
    if router.route_count >= MAX_ROUTES return;
    r := *router.routes[router.route_count];
    r.method = method;
    r.pattern = pattern;
    r.handler = handler;
    router.route_count += 1;
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
    m := *router.mounts[router.mount_count];
    m.prefix = prefix;
    m.router = sub;
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

param :: (name: string) -> string, bool {
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
    // Check mounts first — if path starts with a mount prefix, delegate to sub-router
    for i: 0..cast(s64) router.mount_count - 1 {
        mp := *router.mounts[i];
        if starts_with(req.path, mp.prefix) {
            // Strip the prefix for the sub-router
            original_path := req.path;
            remaining := req.path;
            remaining.data += mp.prefix.count;
            remaining.count -= mp.prefix.count;
            // Ensure sub-path starts with "/" or is empty (becomes "/")
            if remaining.count == 0 {
                req.path = "/";
            } else {
                req.path = remaining;
            }
            dispatch_with_middleware(router, mp.router, req, resp);
            req.path = original_path;
            return;
        }
    }

    // Linear scan routes — match method + pattern
    matched_path := false;
    http_ctx: HTTP_Context;

    for i: 0..cast(s64) router.route_count - 1 {
        r := *router.routes[i];
        http_ctx.param_count = 0;

        if match_pattern(r.pattern, req.path, *http_ctx.params, *http_ctx.param_count) {
            matched_path = true;
            // Check method (empty method = any)
            if r.method.count == 0 || string_equals(r.method, req.method) {
                http_ctx.req = req;
                http_ctx.resp = resp;
                http_ctx.handler = r.handler;

                // Build middleware slice from this router
                mw_slice: [] Middleware;
                mw_slice.data = router.middleware.data;
                mw_slice.count = cast(s64) router.mw_count;
                http_ctx.middleware = mw_slice;
                http_ctx.mw_index = 0;

                ctx := *context;
                ctx.http = *http_ctx;
                push_context ctx.* {
                    proceed(*http_ctx);
                }
                return;
            }
        }
    }

    // No match
    if matched_path {
        // Path matched but method didn't → 405
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
    } else {
        resp.status_code = 404;
        resp.body = "Not Found";
    }
}

// -- Pattern matching (public for testing) --

// Segment-by-segment pattern matching.
// Literal segments must match exactly. `:name` segments match any non-empty segment and capture into params.
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
        // Find end of path segment
        as := ai;
        while ai < path.count && path[ai] != #char "/" {
            ai += 1;
        }

        pat_seg_start := ps;
        pat_seg_end   := pi;
        path_seg_start := as;
        path_seg_end   := ai;

        pat_seg_len  := pat_seg_end - pat_seg_start;
        path_seg_len := path_seg_end - path_seg_start;

        if pat_seg_len > 0 && pattern[pat_seg_start] == #char ":" {
            // Param segment — must match at least one character
            if path_seg_len == 0 return false;

            if param_count.* < MAX_PARAMS {
                p := *params.*[param_count.*];
                // Name is everything after the ':'
                p.name.data = pattern.data + pat_seg_start + 1;
                p.name.count = pat_seg_len - 1;
                // Value is the path segment
                p.value.data = path.data + path_seg_start;
                p.value.count = path_seg_len;
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

// Dispatch into a sub-router, running parent middleware first, then sub-router middleware.
dispatch_with_middleware :: (parent: *Router, sub: *Router, req: *Request, resp: *Response) {
    // Find matching route in sub-router
    matched_path := false;
    http_ctx: HTTP_Context;

    for i: 0..cast(s64) sub.route_count - 1 {
        r := *sub.routes[i];
        http_ctx.param_count = 0;

        if match_pattern(r.pattern, req.path, *http_ctx.params, *http_ctx.param_count) {
            matched_path = true;
            if r.method.count == 0 || string_equals(r.method, req.method) {
                http_ctx.req = req;
                http_ctx.resp = resp;
                http_ctx.handler = r.handler;

                // Merge middleware: parent middleware first, then sub-router middleware.
                // Use temporary storage for the merged array.
                total_mw := cast(s64) parent.mw_count + cast(s64) sub.mw_count;
                if total_mw > 0 {
                    merged := Basic.NewArray(total_mw, Middleware, initialized = false,, allocator = Basic.temp);
                    for j: 0..cast(s64) parent.mw_count - 1 {
                        merged[j] = parent.middleware[j];
                    }
                    for j: 0..cast(s64) sub.mw_count - 1 {
                        merged[cast(s64) parent.mw_count + j] = sub.middleware[j];
                    }
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
        }
    }

    if matched_path {
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
    } else {
        resp.status_code = 404;
        resp.body = "Not Found";
    }
}

starts_with :: inline (s: string, prefix: string) -> bool {
    if s.count < prefix.count return false;
    for i: 0..prefix.count - 1 {
        if s[i] != prefix[i] return false;
    }
    return true;
}
