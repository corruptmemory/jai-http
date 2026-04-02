# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Experimental HTTP server in Jai using epoll-based event-driven I/O on Linux. Features a worker thread pool with SO_REUSEPORT shared-nothing architecture, chi-style router with middleware and context integration, per-request pool allocator, and comprehensive HTTP helpers.

**Current status:** Milestone 3 (routing + helpers) complete, plus datetime, channel, and CSV modules. Chi-style router with path params (`:name`), wildcard segments (`*name`), middleware chains, sub-router mounting, and `#add_context` integration. Response helpers (json/text/html/redirect), URL decoding, query param access, form body parsing, and multipart/form-data parsing. Datetime helpers: RFC3339 parsing, date formatting, Unix epoch conversions, start-of-day, relative time, duration bucketing. CSV module: compile-time validated struct-to-CSV with `#code` AST rewriting for override API, RFC 4180 parsing, header-mapped row reading. 119 tests passing (70 http_server + 19 datetime + 15 channel + 15 CSV). ~1.6M req/s at 32t/2000c with routing overhead.

**Target hardware:** 32-core / 64-thread AMD Threadripper. Be aggressive with threading when we get there.

**Performance reference:** nginx source is checked out at `~/projects/nginx/` — we are reverse-engineering its epoll event loop and connection handling as the performance target for this server. Read `.claude/nginx-reference.md` for a comprehensive cheat-sheet of nginx internals (epoll, connections, pools, buffers, process model, and patterns to replicate).

**Practical application target:** `~/projects/weather-station/` is a Go web application (Ambient Weather WS-2902 receiver) that serves as the milestone for "useful infrastructure." It uses chi router, templ templates, htmx polling, CSV date-partitioned storage, actor-pattern collector goroutine, downsample aggregation, uPlot charts, embedded static files, and TOML config. Rebuilding it with this Jai HTTP library is the next major goal — it exercises routing, static file serving, JSON APIs, shared state via actor pattern, and file I/O.

## Build Commands

The build system is Jai's compile-time metaprogramming via `first.jai`. All builds are invoked through the Jai compiler:

```bash
~/jai/jai/bin/jai-linux first.jai - debug    # Debug build → build_debug/server, build_debug/client
~/jai/jai/bin/jai-linux first.jai - release  # Release build → build_release/server, build_release/client
~/jai/jai/bin/jai-linux first.jai - test     # Build and auto-run tests → build_tests/tests, build_tests/datetime_tests, build_tests/channel_tests
```
**Note:** Single dash `-` separates compiler args from metaprogram args. Double dash `--` is reserved for compiler developer options.

**Compiler flags:** `-release` is deprecated as of 0.2.026. Use `-o` or `-optimized` for release builds, `-od` or `-optimized_debug` for optimized debug. Our build metaprogram handles this via its own `release`/`debug` args, so this only matters if invoking the compiler directly.

Standalone experiments (not part of the build system):
```bash
~/jai/jai/bin/jai-linux experiments/csv_macro_test.jai    # Compile-time override validation
~/jai/jai/bin/jai-linux experiments/csv_insert_test.jai   # #code AST rewriting experiment
```

Run the server: `./build_debug/server` (listens on 0.0.0.0:8080)

## Architecture

**Build metaprogram** (`first.jai`): Creates compiler workspaces (server, client, test suites). The `modules/` directory is added to the import path for all workspaces. Tests are auto-executed after compilation via `Autorun`. The `build_and_run_test` helper creates a test workspace from a workspace name, executable name, and test file path — adding new test suites is a one-liner.

**HTTP Server module** (`modules/http_server/`):
- `module.jai` — Module definition with compile-time parameters: `CACHE_LINE_SIZE`, `READ_BUFFER_SIZE`, `MAX_HEADERS`, `MAX_ROUTES`, `MAX_PARAMS`, `MAX_MIDDLEWARE`, `MAX_MOUNTS`, `MAX_FORM_VALUES`, `MAX_MULTIPART_PARTS`, `LISTEN_BACKLOG`. Imports Basic, Pool, POSIX, Linux, Socket, Thread.
- `http.jai` — HTTP types (Request, Response, Header, Parse_State, Parse_Result), zero-copy incremental parser, response serializer, string helpers (string_equals, string_equals_ci, to_lower). `to_lower` is `#scope_module` so helpers.jai can use it without conflicting with `Basic.to_lower` for importers.
- `connection.jai` — Connection struct with per-connection read buffer, parse state, and request; connection pool with free list and instance-bit recycling.
- `event.jai` — Event_Engine wrapping epoll, connection pointer + instance bit encoding for stale event detection.
- `router.jai` — Chi-style router: `#add_context http: *HTTP_Context`, route types (Route, Router, Mount_Point), route registration (get/post/put/http_delete/route), middleware chains (use/proceed), sub-router mounting (mount), path param access (param), and dispatch with per-request context setup. Pattern matching supports literal segments, `:name` param capture, and `*name` wildcard (rest-of-path) segments.
- `helpers.jai` — Response helpers (json/text/html/redirect), url_decode with zero-copy fast path, query_param lookup, form body parsing (Form_Data/parse_form/form_value), and multipart/form-data parsing (Multipart_Data/parse_multipart/multipart_value).
- `server.jai` — Worker/Server structs, SO_REUSEPORT per-worker sockets, edge-triggered epoll event loop, per-request Pool allocator (reset after each dispatch via `push_context`).

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

**Experiments** (`experiments/`):
- `csv_macro_test.jai` — Proves "constructor validates, value dispatches" pattern in a single file.
- `csv_insert_test.jai` — Proves `#code` AST rewriting in a single file (precursor to csv module).
- `csv_cross_module/` — Proves backtick identifiers solve cross-module `#insert` scoping. Module defines `#expand` macro, caller defines types + functions — backtick-prefixed names in generated strings resolve in caller's scope.

**Entry points:**
- `server/main.jai` — Configures router with routes and starts the HTTP server
- `client/main.jai` — Client stub

## Jai Toolchain

**MANDATORY:** Before writing or modifying ANY Jai code — including in subagents, plan tasks, and background agents — you MUST first invoke the `jai-language` skill using the Skill tool. This loads the comprehensive language reference (syntax, semantics, import rules, operator overloading, named vs anonymous imports, and common pitfalls). This is NOT optional. Do not rely on prior knowledge of Jai; always load the skill first. Additionally, read `.claude/jai-stdlib-reference.md` for a cheat-sheet of all standard library modules and their key APIs.

**Jai compiler version:** Codebase targets beta 0.2.026. When the compiler is updated, check `~/jai/jai/CHANGELOG.txt` (top of file) for breaking changes — especially renamed APIs, deprecated syntax, and removed modules.

The Jai compiler distribution is expected at `~/jai/jai/`. If this path does not exist, ask the user where the Jai distribution is located on this machine. Standard library modules are at `<jai>/modules/` — consult these when using or understanding Jai standard library APIs (Socket, Thread, POSIX, Linux, Atomics, etc.). The `<jai>/how_to/` directory contains detailed annotated examples of every language feature.

## Key Patterns

- No external dependencies — uses only Jai standard library modules (Basic, Pool, Socket, Thread, POSIX, Linux, Atomics, Machine_X64)
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
2. **JSON serialization** — At minimum, serialize structs to JSON strings for API endpoints. Jai's compile-time introspection (`type_info`) makes reflection-based serialization feasible.
3. **CSV read overrides** — `read_row` has no override mechanism (write path has `#code` overrides). Needed for custom parse functions per field (e.g., percentage strings, custom date formats). Should be symmetric with write overrides.

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

## Future Considerations

- **Backend abstraction via module parameter:** Current backend is EPOLL (Linux). Future possibilities: kqueue (macOS), io_uring (Linux alternative), Windows. Could be a `BACKEND` module parameter with conditional compilation — Jai's compile-time `#if` (not a preprocessor!) makes this clean.
- **Any plausible tunable constant should be a module parameter** — they're compile-time constants but configurable at import time.

## Benchmarking

**IMPORTANT:** After each milestone / "got it working" loop, re-run the standard wrk benchmark suite against a release build to track progress. If numbers regress or stall, pause and investigate before moving on.

```bash
~/jai/jai/bin/jai-linux first.jai - release
./build_release/server &
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
