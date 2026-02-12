# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Experimental HTTP server in Jai using epoll-based event-driven I/O on Linux. Features a worker thread pool, cache-line aware blocking channel for work distribution, and stream-based HTTP request parsing.

**Current status:** The server is in an intermediate/non-working state. The goal is nginx-level performance with epoll support.

**Performance reference:** nginx source is checked out at `~/projects/nginx/` — we are reverse-engineering its epoll event loop and connection handling as the performance target for this server. Read `.claude/nginx-reference.md` for a comprehensive cheat-sheet of nginx internals (epoll, connections, pools, buffers, process model, and patterns to replicate).

## Build Commands

The build system is Jai's compile-time metaprogramming via `first.jai`. All builds are invoked through the Jai compiler:

```bash
~/jai/jai/bin/jai-linux first.jai -- debug    # Debug build → build_debug/server, build_debug/client
~/jai/jai/bin/jai-linux first.jai -- release  # Release build → build_release/server, build_release/client
~/jai/jai/bin/jai-linux first.jai -- test     # Build and auto-run tests → build_tests/tests
```

Run the server: `./build_debug/server` (listens on 0.0.0.0:8080)

## Architecture

**Build metaprogram** (`first.jai`): Creates three compiler workspaces (server, client, tests). The `modules/` directory is added to the import path for all workspaces. Tests are auto-executed after compilation via `Autorun`.

**HTTP Server module** (`modules/http_server/`):
- `module.jai` — Module definition, parameterized with `CACHE_LINE_SIZE` (default 64)
- `server.jai` — Core implementation: epoll event loop, worker thread pool, HTTP request parsing, response writing. `generate_method_map()` uses compile-time codegen for HTTP method dispatch.
- `channel.jai` — Generic typed blocking queue (`Channel(T)`) using mutex/condition variables for distributing connections from accept thread to workers
- `connection.jai` — Connection state flags

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
