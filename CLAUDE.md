# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Experimental HTTP server in Jai using epoll-based event-driven I/O on Linux. Features a worker thread pool, cache-line aware blocking channel for work distribution, and stream-based HTTP request parsing.

**Current status:** Milestone 2 complete with full HTTP features — multi-threaded SO_REUSEPORT workers (16 threads, shared-nothing), zero-copy incremental HTTP parser with header lookup, query string separation, request body parsing, and custom response headers. Achieving ~2.5M req/s at 32t/2000c. Next: routing.

**Target hardware:** 32-core / 64-thread AMD Threadripper. Be aggressive with threading when we get there.

**Performance reference:** nginx source is checked out at `~/projects/nginx/` — we are reverse-engineering its epoll event loop and connection handling as the performance target for this server. Read `.claude/nginx-reference.md` for a comprehensive cheat-sheet of nginx internals (epoll, connections, pools, buffers, process model, and patterns to replicate).

## Build Commands

The build system is Jai's compile-time metaprogramming via `first.jai`. All builds are invoked through the Jai compiler:

```bash
~/jai/jai/bin/jai-linux first.jai - debug    # Debug build → build_debug/server, build_debug/client
~/jai/jai/bin/jai-linux first.jai - release  # Release build → build_release/server, build_release/client
~/jai/jai/bin/jai-linux first.jai - test     # Build and auto-run tests → build_tests/tests
```
**Note:** Single dash `-` separates compiler args from metaprogram args. Double dash `--` is reserved for compiler developer options.

Run the server: `./build_debug/server` (listens on 0.0.0.0:8080)

## Architecture

**Build metaprogram** (`first.jai`): Creates three compiler workspaces (server, client, tests). The `modules/` directory is added to the import path for all workspaces. Tests are auto-executed after compilation via `Autorun`.

**HTTP Server module** (`modules/http_server/`):
- `module.jai` — Module definition, parameterized with `CACHE_LINE_SIZE`, `READ_BUFFER_SIZE`, `MAX_HEADERS`
- `http.jai` — HTTP types (Request, Response, Header), zero-copy incremental parser, response serializer, string helpers
- `connection.jai` — Connection struct with per-connection read buffer, parse state, and request; connection pool with free list
- `event.jai` — Event_Engine wrapping epoll, connection pointer + instance bit encoding for stale event detection
- `server.jai` — Worker/Server structs, SO_REUSEPORT per-worker sockets, edge-triggered epoll event loop, handler callback

**Channel module** (`modules/channel/`):
- Standalone generic typed blocking queue (`Channel(T)`) using mutex/condition variables
- Cache-line aware padding for contiguous array items
- Preserved from original implementation for future use

**Entry points:**
- `server/main.jai` — Configures and starts the HTTP server
- `client/main.jai` — Client stub

## Jai Toolchain

**IMPORTANT:** Before writing or modifying Jai code, read `.claude/jai-reference.md` for a comprehensive language reference covering syntax, semantics, and patterns. Also read `.claude/jai-stdlib-reference.md` for a cheat-sheet of all standard library modules and their key APIs.

The Jai compiler distribution is expected at `~/jai/jai/`. If this path does not exist, ask the user where the Jai distribution is located on this machine. Standard library modules are at `<jai>/modules/` — consult these when using or understanding Jai standard library APIs (Socket, Thread, POSIX, Linux, Atomics, etc.). The `<jai>/how_to/` directory contains detailed annotated examples of every language feature.

## Key Patterns

- No external dependencies — uses only Jai standard library modules (Basic, Socket, Thread, POSIX, Linux, Atomics, Machine_X64)
- Compile-time string building for method dispatch table generation
- Cache-line aligned padding in channel items for performance
- Workers use `reset_temporary_storage()` per request for memory efficiency
- Epoll for scalable I/O multiplexing; connections flow from accept thread → Channel → worker threads

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
