# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Experimental HTTP server in Jai using epoll-based event-driven I/O on Linux. Features a worker thread pool with SO_REUSEPORT shared-nothing architecture, chi-style router with middleware and context integration, per-request pool allocator, and comprehensive HTTP helpers.

**Current status:** Milestone 3 (routing + helpers) complete, plus datetime, channel, and CSV modules. Chi-style router with path params (`:name`), wildcard segments (`*name`), middleware chains, sub-router mounting, and `#add_context` integration. Response helpers (json/text/html/redirect), URL decoding, query param access, form body parsing, and multipart/form-data parsing. Datetime helpers: RFC3339 parsing, date formatting, Unix epoch conversions, start-of-day, relative time, duration bucketing. CSV module: compile-time validated struct-to-CSV with `#code` AST rewriting for override API, RFC 4180 parsing, header-mapped row reading. Plus a vendored JSON module (rluba/jaison, MIT): typed struct ⇄ JSON and a generic `JSON_Value` tree. Routing now lives in its own `http_router` module layered on the routing-agnostic `http_server` core (GetRect↔Simp-style split: the core invokes a bare `Handler` and delivers bound state via `#add_context handler_data: *Handler_Data`; `http_router` supplies the dispatch adapter, now **cast-free**). The cast-free path requires the consuming **main program** to wire the core's `Handler_Data` to a Router-compatible type — program parameters can only be supplied from main, never a library, so the consumer that pulls in the optional routing layer does the explicit wiring (no library magic); a consumer that forgets gets a clean, actionable `compiler_report` error, not a silent fallback. `Handler_Data` may be **`Router` itself** *or* **any struct that embeds `Router` via `#as using`** (structural single-inheritance, `$T/Router`-style): the router dispatches cast-free through the embedded `Router`, and handlers read the full typed app-state off `context.handler_data` (also cast-free) — so an app reclaims the single program-wide slot for its own state without giving up routing. See `examples/app_state.jai`. 119 unit tests passing (50 http_server + 20 http_router + 19 datetime + 15 channel + 15 CSV), plus the vendored JSON suite (leak + round-trip harness). ~1.8M req/s at 32t/2000c (beats nginx on a 3970X) after fixing a per-response temporary-storage allocation in `write_response`; per-route routing overhead measured ≈0. Builds and all tests pass on Jai beta 0.2.029. The project has refocused to a **library + examples** layout: build targets are `examples/<name>.jai` driven by `first.jai`'s shape-based grammar (`-release`/`-run`/`run-tests`/`++`), and the native HTTP client was dropped in favor of a future libcurl wrapper.

**Target hardware:** 32-core / 64-thread AMD Threadripper. Be aggressive with threading when we get there.

**Performance reference:** nginx source is checked out at `~/projects/nginx/` — we are reverse-engineering its epoll event loop and connection handling as the performance target for this server. Read `.claude/nginx-reference.md` for a comprehensive cheat-sheet of nginx internals (epoll, connections, pools, buffers, process model, and patterns to replicate).

**Practical application target:** `~/projects/weather-station/` is a Go web application (Ambient Weather WS-2902 receiver) that serves as the milestone for "useful infrastructure." It uses chi router, templ templates, htmx polling, CSV date-partitioned storage, actor-pattern collector goroutine, downsample aggregation, uPlot charts, embedded static files, and TOML config. Rebuilding it with this Jai HTTP library is the next major goal — it exercises routing, static file serving, JSON APIs, shared state via actor pattern, and file I/O.

## Build Commands

The build system is Jai's compile-time metaprogramming via `first.jai`. All builds are invoked through the Jai compiler:

```bash
# Build targets are bare words → examples/<name>.jai. Modifiers start with `-`.
~/jai/jai/bin/jai-linux first.jai -                              # Build ALL examples/*.jai → build_debug/ (no run)
~/jai/jai/bin/jai-linux first.jai - hello_world                 # Build one example → build_debug/hello_world
~/jai/jai/bin/jai-linux first.jai - hello_world -release        # Optimized → build_release/hello_world
~/jai/jai/bin/jai-linux first.jai - hello_world -run            # Build + run (debug)
~/jai/jai/bin/jai-linux first.jai - hello_world ++ --port 9090  # Build + run, forwarding args after `++` (`++` implies -run)
~/jai/jai/bin/jai-linux first.jai - run-tests                   # Build + run ALL suites → build_tests/{tests,router_tests,datetime_tests,channel_tests,csv_tests,json_tests}
~/jai/jai/bin/jai-linux first.jai - run-tests -release          # Same, optimized
```

**Grammar (classified by token shape, not position):** `-release` = optimized (debug is the implied default — there is **no** `-debug`); `-run` = run the single target after building; `run-tests` = the exclusive test verb (build + run all suites; cannot be combined with build targets or `++`); `++` = everything after is passed through to the run target, and its presence implies `-run`; any other bare word is a build target resolved dynamically to `examples/<name>.jai`. `-run`/`++` require exactly one target. **Adding an example is just dropping a file into `examples/`** — no `first.jai` edit.

**Note:** Single dash `-` separates compiler args from metaprogram args. A **standalone** double dash `--` is reserved by the compiler for its own developer options (everything after the last `--` never reaches `compile_time_command_line`) — which is exactly why the passthrough separator is `++`, not `--`. (`--`-*prefixed* tokens like `--port` after `++` pass through fine; only a lone `--` is special.)

**Compiler flags:** The metaprogram chooses optimization itself from its own `-release` modifier (which is a *metaprogram* arg after the `-` separator, distinct from the compiler's deprecated `-release`/`-optimized` flags). You do not pass compiler optimization flags directly.

Standalone experiments (not part of the build system):
```bash
~/jai/jai/bin/jai-linux experiments/csv_macro_test.jai    # Compile-time override validation
~/jai/jai/bin/jai-linux experiments/csv_insert_test.jai   # #code AST rewriting experiment
```

Run an example: `./build_debug/hello_world` (listens on 0.0.0.0:9090)

## Architecture

**Build metaprogram** (`first.jai`): Creates one compiler workspace per build target — an example (`examples/<name>.jai`, discovered dynamically) or a test suite. The `modules/` directory is prepended to the import path for all workspaces. The `build_example` helper compiles an example into `build_debug/`/`build_release/` and optionally runs it (forwarding `++` passthrough args); `build_and_run_test` compiles a test suite and auto-runs it via `Autorun`. Adding a new example is just dropping a file into `examples/`; adding a test suite is a one-line `build_and_run_test` call. See "Build Commands" for the full target grammar.

**HTTP Server module — the routing-agnostic core** (`modules/http_server/`):
- `module.jai` — Module definition. Group-1 (per-import) params: `CACHE_LINE_SIZE`, `READ_BUFFER_SIZE`, `MAX_HEADERS`, `MAX_FORM_VALUES`, `MAX_MULTIPART_PARTS`, `LISTEN_BACKLOG`. Group-2 (program-wide) param: `Handler_Data: Type = void` — the type of the bound state delivered to handlers via `#add_context handler_data: *Handler_Data` (`*void` by default; a concrete `*T` when a consumer injects one, then cast-free). Imports Basic, Pool, POSIX, Linux, Socket, Thread. The core never references `Router` — routing is the optional `http_router` layer.
- `http.jai` — HTTP types (Request, Response, Header, Parse_State, Parse_Result), the bare `Handler :: #type (req, resp)` contract, zero-copy incremental parser, response serializer, string helpers (string_equals, string_equals_ci, to_lower). `to_lower` is `#scope_module` so helpers.jai can use it without conflicting with `Basic.to_lower` for importers.
- `connection.jai` — Connection struct with per-connection read buffer, parse state, and request; connection pool with free list and instance-bit recycling.
- `event.jai` — Event_Engine wrapping epoll, connection pointer + instance bit encoding for stale event detection.
- `helpers.jai` — Response helpers (json/text/html/redirect), url_decode with zero-copy fast path, query_param lookup, form body parsing (Form_Data/parse_form/form_value), and multipart/form-data parsing (Multipart_Data/parse_multipart/multipart_value). Routing-independent — stays in the core.
- `server.jai` — Worker/Server structs, SO_REUSEPORT per-worker sockets, edge-triggered epoll event loop, per-request Pool allocator (reset after each dispatch via `push_context`). `serve(*Server, Handler, *Handler_Data)` wires any bare handler in; the core is unaware of routing.

**HTTP Router module — optional routing layer** (`modules/http_router/`):
- `module.jai` — Own group-1 params (`MAX_ROUTES`, `MAX_PARAMS`, `MAX_MIDDLEWARE`, `MAX_MOUNTS` — they describe the router, not the core). Bare `#import "http_server"` (inherits the program-wide `Handler_Data`), `#import "Basic"`, `Compiler :: #import "Compiler"` (compile-time only, for the friendly error), `#load "router.jai"`.
- `router.jai` — Chi-style router: `#add_context http: *HTTP_Context`, route types (Route, Router, Mount_Point), route registration (get/post/put/http_delete/route), middleware chains (use/proceed), sub-router mounting (mount), path param access (param), and dispatch with per-request context setup. Pattern matching supports literal segments, `:name` param capture, and `*name` wildcard (rest-of-path) segments. The `route_handler` adapter bridges the core's bare `Handler` to `dispatch()` **cast-free**: `#if #run handler_data_is_router(type_of(context.handler_data))` it dispatches directly (the `*Handler_Data → *Router` conversion is implicit); the `else` arm is `#run Compiler.compiler_report(...)` — a hard, human-friendly compile error (no silent fallback). `handler_data_is_router` is a compile-time `type_info` predicate (in the `#scope_file` region): true when `Handler_Data` is `Router` or a struct with an `#as` member (flag `AS`) of type `Router`, recursively — i.e. exactly when `*Handler_Data` is assignable to `*Router`. `serve(*Server, *$T/Router)` is **polymorphic** (`$T/Router` structural restriction) so the full `*T` passes straight through as the core's bound state (no downcast), keeping `context.handler_data` typed `*T` for handlers. **Consumers wire it in `main`:** `#import "http_server"()(Handler_Data = http_router.Router)` (or `= App` where `App` embeds Router via `#as using`) + `http_router :: #import "http_router"` (named, to namespace `serve`); tests import both anonymously and reference `Router` directly. Needs `Compiler :: #import "Compiler"` (compile-time only). See `docs/plans/2026-06-19-handler-context-refactor-design.md`.

**Datetime module** (`modules/datetime/`):
- `module.jai` — RFC3339 parsing (handles both `T` and `+` separators for AmbientWeather), date formatting (`YYYY-MM-DD`), Unix epoch conversions (`to_unix`/`from_unix`), `start_of_day`, `hours_ago`/`days_ago` relative time, `bucket_start` for duration-aligned bucketing. Uses anonymous `#import "Basic"` (not named) to bring Apollo_Time operators into scope.
- `tests/test.jai` — 19 tests covering parse/format/roundtrip, epoch arithmetic, wall-clock tolerance, and bucket alignment.

**Channel module** (`modules/channel/`):
- Standalone generic typed blocking queue (`Channel(T)`) using mutex/condition variables
- Cache-line aware padding for contiguous array items
- API: `init`, `destroy`, `send` (blocks when full), `receive` (returns `(T, bool)` — blocks when empty, `ok=false` when closed+empty), `close` (wakes all blocked threads)
- Proper shutdown semantics: `close` sets flag + broadcasts on both condition variables; `send` rechecks `closed` after waking from full-buffer wait; `receive` drains buffered items before reporting closure
- `tests/test.jai` — 15 tests covering single-threaded ops, multi-threaded producer/consumer, and close behavior
- Used for shared state via actor pattern (see "Shared State Architecture" below)

**CSV module** (`modules/csv/`):
- `module.jai` — Compile-time validated CSV read/write. `@"csv:NAME"` notes for column naming, `@"csv:-"` to skip fields. `csv_write_row` is an `#expand` macro: accepts `#code .[ make_override("field", fn) ]`, walks AST at compile time via `compiler_get_nodes`, validates field names, generates `make_override_internal` calls with backtick-prefixed caller-scope identifiers. Two-phase validation: AST walk (field existence) + polymorph `#assert` (signature matching). Runtime: type-erased `Writer_Fn` dispatch. `read_row` maps CSV fields to struct via header column names. `split_line` handles RFC 4180 (quoted fields, escaped double-quotes).
- `tests/test.jai` — 15 tests covering note parsing, split_line edge cases, write/read paths, overrides.

**JSON module** (`modules/json/`):
- **Vendored third-party** module from [rluba/jaison](https://github.com/rluba/jaison) (MIT, commit `2009cdb`). Provenance + the short list of local changes are in the header of `module.jai`. Module sources are verbatim; only `tests/test.jai` was adapted (load path + assertions + a pass-summary line) to join our suite.
- Two interfaces: **typed** (reflection-based struct ⇄ JSON, the common case) and **generic** (`JSON_Value` tagged-union tree for unknown shapes). They compose — a struct field typed as `JSON_Value`/`*JSON_Value` is parsed generically.
- API: `json_parse_string(str, T)` / `json_parse_string(str)` (generic) / `json_parse_file(...)`, `json_write_string(value, ...)` / `json_write_file(...)`, `json_escape_string`. Notes `@JsonName(x)` / `@JsonIgnore` (with pluggable `rename`/`ignore` procs). Configurable NaN/Inf handling via `Special_Float_Handling`.
- Dependency: bundled `unicode_utils/` (rluba's jai-unicode, MIT) for `\uXXXX` decode — vendored alongside, resolved via `#import,dir "./unicode_utils"`.
- **Perf note for the server hot path:** `parse_object` rebuilds a member lookup `Table` per object instance parsed (upstream flags this `@Speed`). Serialization is unaffected; only high-volume *parsing* would want this cached per type. Non-blocker today.
- `tests/test.jai` — jaison's MEMORY_DEBUGGER leak harness: malformed-input rejection, typed/generic round-trips, and ~300 parse iterations checked for leaks. Reports `0 bytes leaked` at every checkpoint.

**Experiments** (`experiments/`):
- `csv_macro_test.jai` — Proves "constructor validates, value dispatches" pattern in a single file.
- `csv_insert_test.jai` — Proves `#code` AST rewriting in a single file (precursor to csv module).
- `csv_cross_module/` — Proves backtick identifiers solve cross-module `#insert` scoping. Module defines `#expand` macro, caller defines types + functions — backtick-prefixed names in generated strings resolve in caller's scope.

**Entry points:**
- `examples/hello_world.jai` — Example program: configures a router and starts the HTTP server on `0.0.0.0:9090`. Build targets are discovered dynamically from `examples/*.jai`; add more examples by dropping files here.

**No native HTTP client.** A from-scratch client (TLS, HTTP/2, HTTP/3, redirects, cookies, cert chains) is a correctness tarpit that libcurl already owns, so the client will be a thin libcurl wrapper (future, separate module) — not native Jai. The old `client/` stub has been removed.

## Jai Toolchain

**MANDATORY:** Before writing or modifying ANY Jai code — including in subagents, plan tasks, and background agents — you MUST first invoke the `jai-language` skill using the Skill tool. This loads the comprehensive language reference (syntax, semantics, import rules, operator overloading, named vs anonymous imports, and common pitfalls). This is NOT optional. Do not rely on prior knowledge of Jai; always load the skill first. Additionally, read `.claude/jai-stdlib-reference.md` for a cheat-sheet of all standard library modules and their key APIs.

**Jai compiler version:** Builds and all tests pass on beta 0.2.029 (verified 2026-06-18). When the compiler is updated, check `~/jai/jai/CHANGELOG.txt` (top of file) for breaking changes — especially renamed APIs, deprecated syntax, and removed modules.

The Jai compiler distribution is expected at `~/jai/jai/`. If this path does not exist, ask the user where the Jai distribution is located on this machine. Standard library modules are at `<jai>/modules/` — consult these when using or understanding Jai standard library APIs (Socket, Thread, POSIX, Linux, Atomics, etc.). The `<jai>/how_to/` directory contains detailed annotated examples of every language feature.

## Key Patterns

- Batteries included, no install step — builds with only the Jai compiler; nothing to install at runtime. First-party code uses only Jai standard library modules (Basic, Pool, Socket, Thread, POSIX, Linux, Atomics, Machine_X64); third-party code (currently JSON, from rluba/jaison) is **vendored in-tree** under `modules/`, never fetched by a package manager. The resulting binary dynamically links system `.so`s (libc, etc. — visible via `ldd`); fully-static musl linking is explicitly not a goal.
- **Per-request pool allocator:** Each Worker owns a `Pool` (from `#import "Pool"` — NOT `Flat_Pool`). Before dispatch, `push_context` swaps `context.allocator` to the pool. After dispatch, `Pool_Module.reset()` bulk-frees all per-request allocations. Handler code uses `alloc()`, `New()`, etc. with automatic per-request cleanup.
- **Why Pool, not Flat_Pool:** Flat_Pool reserves large contiguous virtual address space via mmap (default 256MB). With 16 workers that's 4GB VIRT — misleading in htop. Pool allocates 64KB heap blocks on demand, recycles on reset(), only shows actual RSS.
- **Module scoping gotchas:** `#scope_file` restricts to the file, `#scope_module` makes visible within the module but not to importers, default scope exports to importers. When utility functions are needed across module files but shouldn't conflict with standard library names (e.g. `to_lower`), use `#scope_module`.
- **Named vs anonymous imports and operators:** A named import (`Basic :: #import "Basic"`) namespaces everything under `Basic.`, meaning bare `assert`, `free`, `NewArray` etc. won't compile — they need `Basic.assert`, `Basic.free`, etc. Operator overloads for types like `Apollo_Time` (inherited from `S128` via `#type,isa`) also don't propagate through namespaces. **Prefer anonymous imports** (`#import "Basic"`) for modules that use Basic broadly (datetime, channel modules). Named imports are useful when you want to avoid polluting the namespace or only call a few qualified functions (http_server module).
- **Module parameters aren't exported:** Importers can't reference `MAX_PARAMS` etc. In test code, use `type_of(HTTP_Context.params)` to get the array type instead.
- Workers use `reset_temporary_storage()` per epoll iteration for memory efficiency
- Epoll for scalable I/O multiplexing; each worker has its own listen socket via SO_REUSEPORT (shared-nothing, no inter-worker communication)
- Zero-copy parsing throughout: HTTP parser, URL decoder, form parser, multipart parser all use string views into the connection buffer where possible
- **Idiomatic Jai patterns:** `ifx` for conditional expressions, `#specified` on enums with explicit values (enforces all variants have assigned values), named return values for self-documenting multi-return APIs (e.g. `-> (value: string, found: bool)`)
- **Thread API vs Thread_Group:** Raw `Thread` (`thread_init`, `thread_start`, `thread_is_done`, `thread_deinit`) is for one-shot threads with custom procs. `Thread_Group` is a work-stealing thread pool — all threads run the same callback, work is dispatched via `add_work()` / `get_completed_work()`. Use raw Thread for actor/consumer patterns; Thread_Group for parallel data processing.
- **"Constructor validates, value dispatches" pattern:** When you need compile-time validation + runtime dispatch, put all validation in a function with `$`-baked params (`$S: Type, $name: string, $fn: $F`). `#assert` fires at compile time during polymorph generation. The return value carries runtime data (e.g. `cast(*void) fn`). The overrides array is `:=` (runtime), not `::` (constant), because function pointers aren't compile-time constants.
- **`#code` AST rewriting pattern:** `#import "Compiler"` gives access to `compiler_get_nodes(code)` which returns a flat list of all AST nodes. Define a helper inside an `#expand` macro, call it with `#run`, walk/modify the AST or generate a string, and `#insert,scope()` the result. `#code` delays name resolution — identifiers don't need to exist until insertion. This enables "phantom function" patterns where user writes a clean API in `#code` and the macro rewrites it. **Cross-module gotcha:** `#insert` of a generated string inside an `#expand` macro resolves in the module's scope, not the caller's. Use backtick-prefixed identifiers (`` `Name ``) in the generated string for caller-scope names (types, functions). Module-defined names don't need backticks. See `modules/csv/module.jai` (production) and `experiments/csv_cross_module/` (proof-of-concept).
- **Debugging `#insert`:** The compiler writes all `#insert`-ed strings to `.build/.added_strings_wN.jai` (hidden dot-prefixed file). Inspect this to see exactly what code was generated and inserted, with source locations. Invaluable for debugging `#code` + `#insert` macro patterns.

## Shared State Architecture

The 16 SO_REUSEPORT workers are shared-nothing — they don't communicate with each other. For application state that must be shared across workers (e.g. latest weather observation, in-memory data store):

- **Actor pattern via Channel:** A single owner thread holds all mutable state. Workers send typed commands via `Channel(Command)` where `Command` is a tagged union of all message types (new observation, query latest, query history, flush to disk, etc.). The owner thread blocks on `receive()`, switches on command type, and replies through a response channel when needed.
- **No need for Go's `select`:** A single `Channel(Command)` with tagged union eliminates multi-channel multiplexing. The collector thread just blocks on one channel.
- **Future enhancement:** `try_send`/`try_receive` (non-blocking) could enable polling multiple channels, but would spin. A condition-variable-based approach (like epoll for channels) would be ideal for true `select` semantics, but this is not a blocker for current application targets.

## Remaining Library Gaps

Before the weather station app can be rebuilt in Jai, these library-level features are needed:

1. **Static file serving handler** — Thin wrapper: map wildcard path to embedded bytes (via `#run read_entire_file()`), set Content-Type from file extension, write body. Wildcard routes (`*filepath`) are already implemented.
2. **CSV read overrides** — `read_row` has no override mechanism (write path has `#code` overrides). Needed for custom parse functions per field (e.g., percentage strings, custom date formats). Should be symmetric with write overrides.

**NOT gaps** (already covered):
- Routing: chi-style router with params, wildcards, middleware, mounting ✓
- Static file embedding: Jai's `#run read_entire_file()` at compile time ✓
- File I/O: Jai's `File` standard library module ✓
- Shared state: Channel module + actor pattern ✓
- Form/multipart parsing: helpers.jai ✓
- Query params: helpers.jai ✓
- Time/date handling: datetime module (RFC3339 parsing, date formatting, Unix epoch, start-of-day, relative time, duration bucketing) ✓
- Float formatting: `formatFloat(value, trailing_width=1, zero_removal=.NO)` ✓
- CSV read/write: `modules/csv/` — `csv_write_row` (#expand macro with `#code` override API), `read_row` (header-mapped), `split_line` (RFC 4180), `@"csv:NAME"` notes. 15 tests. ✓
- JSON serialization & parsing: `modules/json/` — vendored rluba/jaison (MIT). Typed struct ⇄ JSON + generic `JSON_Value` tree, `@JsonName`/`@JsonIgnore` notes, NaN/Inf handling. Closes the former "JSON serialization" gap and adds parsing too. ✓

## Future Considerations

- **Backend abstraction via module parameter:** Current backend is EPOLL (Linux). Future possibilities: kqueue (macOS), io_uring (Linux alternative), Windows. Could be a `BACKEND` module parameter with conditional compilation — Jai's compile-time `#if` (not a preprocessor!) makes this clean.
- **Any plausible tunable constant should be a module parameter** — they're compile-time constants but configurable at import time.

## Benchmarking

**IMPORTANT:** After each milestone / "got it working" loop, re-run the standard wrk benchmark suite against a release build to track progress. If numbers regress or stall, pause and investigate before moving on.

```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
./build_release/hello_world &
wrk -t1 -c10 -d10s http://localhost:9090/
wrk -t4 -c100 -d10s http://localhost:9090/
wrk -t8 -c500 -d10s http://localhost:9090/
wrk -t16 -c1000 -d10s http://localhost:9090/
wrk -t32 -c2000 -d10s http://localhost:9090/
kill %1
```

### Benchmark History

**Milestone 1** (single-threaded, Connection: close, hardcoded Hello World):
| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|------------|---------|-------------|
| 1 | 10 | 25,693 | 138us |
| 4 | 100 | 54,963 | 1.7ms |
| 8 | 500 | 48,439 | 10.1ms |
| 16 | 1000 | 45,283 | 21.6ms |

**Milestone 1 + Keep-Alive** (single-threaded, keep-alive enabled, hardcoded Hello World):
| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|------------|---------|-------------|
| 1 | 10 | 163,686 | 39us |
| 4 | 100 | 158,671 | 627us |
| 8 | 500 | 142,924 | 3.5ms |
| 16 | 1000 | 142,542 | 6.9ms |

**Milestone 2** (16 SO_REUSEPORT workers, keep-alive, hardcoded Hello World):
| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|------------|---------|-------------|
| 1 | 10 | 130,548 | 47us |
| 4 | 100 | 386,276 | 148us |
| 8 | 500 | 712,990 | 387us |
| 16 | 1000 | 1,451,350 | 422us |

**Milestone 2 + HTTP Parser** (16 workers, zero-copy parser, handler callback, Hello World):
| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|------------|---------|-------------|
| 1 | 10 | 143,808 | 4.8ms |
| 4 | 100 | 392,882 | 4.4ms |
| 8 | 500 | 689,251 | 4.4ms |
| 16 | 1000 | 1,360,520 | 4.4ms |
| 32 | 2000 | 2,489,878 | 4.2ms |

**Milestone 3** (16 workers, chi-style router + middleware + pool allocator, Hello World):
| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|------------|---------|-------------|
| 32 | 2000 | ~1,600,000 | ~4ms |

Router dispatch adds ~36% overhead at 32t/2000c vs raw handler callback (2.49M → 1.6M). Investigated: pool allocator is NOT the cause (same numbers with/without it). The overhead is from push_context, match_pattern segment scanning, and middleware chain setup. Acceptable cost for routing functionality — optimization opportunity for later (e.g. radix tree, compiled dispatch table).

> **SUPERSEDED — that 36% was a cross-milestone artifact, not isolated routing cost.** It compared Milestone 2's raw callback (2.49M) against Milestone 3's router (1.6M) — two builds differing in more than routing. A proper apples-to-apples A/B on the post-refactor core (raw vs routed through the *same* machinery) shows routing-one-route overhead is ≈ 0. See "Routing-overhead A/B" below.

**Milestone 3 + TCP_NODELAY + writev** (i7-12800H laptop, 20 logical cores, sysctl-tuned):
| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|------------|---------|-------------|
| 1 | 10 | 245,591 | 25us |
| 4 | 100 | 630,698 | 88us |
| 8 | 500 | 951,780 | 505us |
| 16 | 1000 | 929,938 | 1.26ms |
| 32 | 2000 | 859,438 | 2.42ms |

Numbers plateau and drop above 8t/500c: 16 server workers + 32 wrk threads = 48 threads on 20 cores causes scheduler oversubscription. These numbers are hardware-limited by the laptop. The Threadripper (64 logical cores, no oversubscription) is the meaningful benchmark target.

**Nagle × Delayed ACK — the two-send deadlock (diagnosed and fixed):**
`write_response` was making two separate `send_all()` calls (headers, then body). Without `TCP_NODELAY` this triggers a well-known deadlock: Nagle buffers the body (waiting for ACK of headers), but the client uses delayed ACKs (waits up to 40ms to piggyback the ACK). Both sides wait on each other — 40ms stall per response, reducing 32t/2000c throughput to ~87K req/s.

`TCP_NODELAY` breaks the deadlock (87K → 850K), but with two separate sends it now emits two TCP segments per response instead of one (doubling packet overhead). Fixed by switching to `writev()`: sends `[headers, body]` atomically in a single syscall → one TCP segment regardless of Nagle state. `write_response` now builds the full header into a temp-allocated string (fast path: `tprint`; slow path: `String_Builder` with `Basic.temp`) and calls `writev()` once.

**Host setup notes (i7-12800H, Artix Linux):**
- `ulimit -n 65536` required for wrk at 32 threads (set in `/etc/security/limits.conf`)
- `/etc/sysctl.d/99-benchmark.conf`: somaxconn=65535, netdev_max_backlog=65535, tcp_max_syn_backlog=65535, ip_local_port_range=1024-65535, tcp_slow_start_after_idle=0, tcp_fin_timeout=15
- CPU governor: `echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` (Intel P-state active mode, energy_performance_preference already set to performance)

**Routing-overhead A/B** (2026-06-19, 64 logical cores, post handler/context refactor; `hello_world` routed vs `hello_world_raw` bare handler — identical `"Hello, World!"` response through the *same* core machinery):

| wrk | raw (no routing) | routed (chi router) | delta |
|-----|------------------|---------------------|-------|
| t1 / c10  (3-rep avg) | 115,040 | 115,696 | +0.6% (noise) |
| t4 / c100 (3-rep avg) | 351,106 | 351,251 | +0.04% (noise) |
| t8 / c500  (1 run)    | 669,576 | 676,263 | — |
| t16 / c1000 (1 run)   | 764,377 | 938,276 | — (variance) |
| t32 / c2000 (1 run)   | 891,857 | 976,468 | — (variance) |

**Finding:** for a *single* route, routing adds **no measurable overhead** — the low-noise points (3 reps each) overlap, so routed-vs-raw is ≈ 0. The router's fixed per-request cost (one `match_pattern` on `/`, method check, `HTTP_Context` build, inner `push_context`) is lost in the noise. The high-concurrency single-run points are variance-dominated (routed nominally ≥ raw is noise, not a real speedup — would need averaging). The real routing cost is **O(route count)**: `dispatch` linearly scans routes calling `match_pattern` per route, so it grows with the number of routes and a late match pays for every earlier miss — *that* is the radix-tree / compiled-dispatch target, not fixed overhead, and it only shows up as routes multiply. Absolute numbers here are NOT comparable to the milestone entries above (different machine/build/date); only the raw-vs-routed delta measured together is meaningful. Methodology + design: `docs/plans/2026-06-19-handler-context-refactor-design.md`.

**High-concurrency collapse — root-caused and fixed** (2026-06-19, Threadripper 3970X 64T, tuned; mitigations toggled during investigation, final state ON):

| wrk | collapse (bug) | **fixed (Pool)** | nginx (control, 16w + reuseport) |
|-----|---------------:|-----------------:|---------------------------------:|
| t8 / c500   | 819K  | 1.03M | 1.03M |
| t16 / c1000 | ~480K | **1.78M** | 1.65M |
| t32 / c2000 | ~519K | **1.81M** | 1.56M |

Throughput collapsed at t16+ (to ~half of t8) while the box sat ~70% idle. Root cause: `write_response` formatted the header with `tprint`, which is **hardwired to temporary storage** (ignores `context.allocator`). The default temp storage is **16 KB per worker thread**, reset only per epoll *batch*; under load a batch serves dozens of requests, overflowing temp storage into repeated heap page allocations (`add_new_page` — perf showed ~45% of CPU). Fix: route header formatting through the **per-request Pool** (`sprint`/`String_Builder` on `context.allocator`) and send the response *inside* the Pool `push_context`, resetting the Pool after — so every per-request allocation (handler scratch + response header) recycles through one allocator. The collapse vanished and we now beat nginx on the same box. The nginx control was decisive: it scaled cleanly under identical conditions, proving the ceiling was our code (the one path that bypassed the Pool), not the kernel/loopback/governor/mitigations. Full investigation + **reproducible environment setup**: `docs/plans/2026-06-19-perf-collapse-investigation.md`.

**Host setup notes (Threadripper 3970X, Artix/OpenRC):** governor → `performance` via `/etc/local.d/cpu-governor.start` (amd-pstate-epp; `local` service enabled); sysctls in `/etc/sysctl.d/99-benchmark.conf` (`sysctl` service in `boot`); `nofile` 65536/524288 in `/etc/security/limits.conf`. `mitigations=off` was tested (+~50% at low concurrency) then reverted — final state mitigations ON. CPU stayed ~70% idle even at peak, so deeper kernel tuning (C-states, flow steering) could push higher; not pursued. See the investigation doc for exact, repeatable steps.
