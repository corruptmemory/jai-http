# Handler / Context Refactor + Routing-Overhead Benchmark

**Date:** 2026-06-19
**Status:** Approved
**Files:** `modules/http_server/{module,server,router}.jai`, `examples/hello_world_raw.jai`

## Goal

Separate concerns: the **core** HTTP server (accept, epoll, zero-copy parse, keep-alive,
`writev`, per-request pool) is the valuable, reusable machinery; **routing is an optional
layer built on top**. Then add a no-routing example and quantify the routing layer's cost
with `wrk`.

This mirrors Go's `net/http`: `Server.Handler` is just a `Handler`; `ServeMux` (the router)
is one implementation. The core never mentions routing.

## Design

### 1. The handler primitive (core, `server.jai`)
```jai
Handler :: #type (req: *Request, resp: *Response);     // == the existing Route_Handler; unify them
```
A bare `(req, resp)`. The router's leaf handlers already have this exact shape, so route
handlers and top-level handlers become one type (like Go's `HandlerFunc`).

### 2. Bound state via context + a program type-parameter
Jai has no closures, so a handler's bound state ("receiver") is delivered through the
**context** — already the idiom here (`#add_context http: *HTTP_Context`; and Simp's
`#add_context simp`). To keep it **type-safe instead of `*void`**, the payload type is a
module **program parameter** (GetRect's `Type_Indicator` pattern):

```jai
// module.jai
#module_parameters ( /* existing value params */ )( Handler_Data: Type = void );

// server.jai
#add_context handler_data: *Handler_Data;              // *void by default; *App_State when injected
serve :: (server: *Server, handler: Handler, data: *Handler_Data = null) { ... }
```
It **must** be a second-group (program-wide) parameter: there is one `Context` type per
program, so the field's type cannot vary per-import. Default `void` ⇒ `*void` (generic);
a consumer-injected type ⇒ fully typed, **zero casts in handler code**.

Delivery (no thread-inheritance reliance — `thread_init` copies only allocator/logger/temp
storage, not custom context fields): `server_run` copies `server.handler`/`handler_data`
into each worker (as it does today for `router`); `handle_client` pokes it per request into
the context it already builds for the pool allocator:
```jai
new_ctx := context;
new_ctx.allocator    = .{ Pool_Module.pool_allocator_proc, *w.request_pool };
new_ctx.handler_data = w.handler_data;
push_context new_ctx { w.handler(*c.req, *response); }
```
`server.jai` no longer references `Router`.

### 3. Router as an optional in-module layer (`router.jai`)
```jai
route_handler :: (req: *Request, resp: *Response) { dispatch(cast(*Router) context.handler_data, req, resp); }
serve :: (server: *Server, router: *Router) { serve(server, route_handler, router); }   // Handler_Data = void
```
`Router` is the library's own type, so the module can't be parameterized by it (circular).
The router therefore rides the default `void` slot with **one internal cast**, contained
entirely in `route_handler` — never in user code. Routing thus uses the default
parameterization; a typed `Handler_Data` is for serving a single app handler cast-free.

### 4. Examples
- `examples/hello_world.jai` (routed) — **unchanged**; `serve(*server, *router)` resolves to the overload.
- `examples/hello_world_raw.jai` (new) — `serve(*server, hello)` with `hello :: (req, resp) { resp.status_code = 200; resp.body = "Hello, World!"; }`. No router.

## Committed next step (NON-NEGOTIABLE)

Extract the router into its **own module** (e.g. `modules/http_router/`) that does
`#import "http_server"()(Handler_Data = Router)`. Then `route_handler` reads
`context.handler_data` already typed as `*Router` and the last cast disappears — the core
stays 100% routing-agnostic, the GetRect↔Simp split realized in full. The in-module cast
above is a temporary bridge only. (Tracked in auto-memory `router-own-module-extraction`.)

### Progress (2026-06-19, branch `routing-module`)

**Structural extraction — DONE.** `router.jai` now lives in `modules/http_router/`
(`module.jai` + `router.jai` + `tests/test.jai`). The module owns the routing limits
(`MAX_ROUTES`/`MAX_PARAMS`/`MAX_MIDDLEWARE`/`MAX_MOUNTS`) as its own group-1 params,
`#import "http_server"` (default `Handler_Data = void`) + `#import "Basic"`, and `#load`s the
router. The core (`http_server`) no longer `#load`s `router.jai` and holds zero `Router`
references. Routing tests split into the new `http_router` suite (20 tests; core keeps 50);
`first.jai` registers `router_tests`. The routed example dual-imports: anonymous
`#import "http_server"` + `http_router :: #import "http_router"` (named, so the two `serve`s
never collide). All six suites pass; both examples build; `GET /`→200, `GET /missing`→404
verified live. The cross-module `serve` overload resolved with **no** collision (named import
made it moot anyway).

**Cast-free finish — DONE (2026-06-19).** `route_handler` is now cast-free.

**Key discovery that reshaped the plan:** the design's original mechanism — `http_router` doing
`#import "http_server"()(Handler_Data = Router)` — is **illegal**. The compiler rejects it:
*"This #import provides program parameters, but is not located in the main program. Program
parameters can only be supplied from the main program."* A library module **cannot** supply program
parameters at all; only the main program file can. (User's framing, and the right one: the consumer
who pulls in the optional dependency does the explicit wiring — not the library. Library-supplied
program params would be magic, and magic is discouraged.)

So the cast-free contract is:
- `http_router/module.jai` does a **bare** `#import "http_server"` — it *inherits* the program-wide
  `Handler_Data`.
- The consuming **main program** sets it: `#import "http_server"()(Handler_Data = http_router.Router)`.
  Examples do this with a named `http_router :: #import "http_router"`; test mains import both
  anonymously and reference `Router` directly (order-independent — `Router` resolves from the
  anonymous `http_router` import). `Handler_Data = http_router.Router` forward-references the
  later import fine.
- `route_handler` is `#if type_of(context.handler_data) == *Router { dispatch(...) }` (cast-free) with
  an `else` arm of `#run Compiler.compiler_report(<friendly message>)`. This is **not** a silent
  fallback: a consumer that forgets to wire gets a clean, actionable compile error (no
  `#assert`/"assertion failed" boilerplate — `compiler_report` owns the whole message). The bare
  `*Router` won't parse on the RHS of `==` in expression position, so it goes through a named
  constant (`EXPECTED_HANDLER_DATA :: *Router`).

Verified: all 6 suites pass, both examples build, `GET /`→200 / `GET /missing`→404 live, and the
unwired-consumer error message confirmed.

**Generalization — `Handler_Data` need not be exactly `Router` (2026-06-19).** The earlier worry that
the program-wide slot is "spent on `Router`" is **lifted**. `route_handler` now accepts `Handler_Data`
that is `Router` **or any struct that embeds `Router` via `#as using`** (structural single-inheritance —
the `$T/Router` relation). Mechanism:
- `route_handler` guards with `#if #run handler_data_is_router(type_of(context.handler_data))`, a
  compile-time `type_info` predicate (the how_to/160 `assert_in_body` style): true iff `Handler_Data`
  is `Router`, or a struct with an `#as` member (member flag `AS`, *not* plain `USING`) of type
  `Router`, recursively — i.e. iff `*Handler_Data` is assignable to `*Router`. (`#if` needs a constant,
  so the call is wrapped in `#run`.) The true branch dispatches via the implicit `*Handler_Data → *Router`
  conversion; the else branch is the `compiler_report` error (message updated to teach the `#as using`
  option).
- `serve` became `serve :: (server: *Server, router: *$T/Router)` — polymorphic with the structural
  restriction — so the FULL `*T` (e.g. `*App`) passes straight through to the core's bound-state slot
  with no downcast, keeping `context.handler_data` typed `*App` for handlers.

So an app reclaims the single `Handler_Data` slot for its own state *and* keeps routing:
```jai
App :: struct { #as using router: http_router.Router;  greeting: string; }
#import "http_server"()(Handler_Data = App);
// handler: app := context.handler_data;  // *App, cast-free; router still dispatches cast-free
```
Verified live via `examples/app_state.jai` (`/`→200 with app-state body, `/missing`→404), all 6 suites
green, and the precise-rejection cases (plain `using` without `#as`, and `void`) both fail loudly at
compile time. Mechanism reference: `how_to/160_type_restrictions.jai` (`$T/R` + `#as using`).

## Benchmark methodology (the A/B)

Release build, both examples, identical response (`"Hello, World!"`). Same `wrk` grid the
CLAUDE.md uses; run each example back-to-back, kill between:
```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
~/jai/jai/bin/jai-linux first.jai - hello_world_raw -release
# for each binary:  ./build_release/<name> &  ; wrk -t1 -c10 / -t4 -c100 / -t8 -c500 / -t16 -c1000 / -t32 -c2000 -d10s http://localhost:9090/ ; kill
```
The raw vs routed delta at each point = the routing layer's cost (`route_handler` indirection
+ `dispatch`: match_pattern, method check, `HTTP_Context` build, inner `push_context`, proceed).
Record results in CLAUDE.md's Benchmark History. Caveat to note: the new architecture adds one
indirect call at the server boundary to *both* paths vs. the old direct `dispatch(w.router…)`,
so re-measure both on the new code — don't compare against pre-refactor numbers.

## Verification
`run-tests` stays green (dispatch/match_pattern signatures unchanged; tests untouched) → both
examples build → `wrk` A/B → record numbers.
