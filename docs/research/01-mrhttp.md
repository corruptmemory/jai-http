# mrhttp — TechEmpower r23 Plaintext #1 (28,384,305 req/s)

## Summary
mrhttp is an asynchronous Python 3.5+ web micro-framework whose entire hot path
is a C extension module (`mrhttp.internals`); the Python layer (`app.py`) is just
route registration and handler glue. It runs as a **process-per-core** prefork
(one process per logical CPU) on top of **uvloop** (libuv → epoll), and its speed
comes from doing all parsing, response assembly, and — crucially — **HTTP
pipelining** in C with a hand-written SIMD-friendly parser, so a single `recv`
that carries dozens of pipelined requests is parsed and answered with almost no
Python or per-request syscall overhead. The TFB plaintext number (28.4M req/s) is
a *pipelined* result; mrhttp's own README reports ~708K req/s for non-pipelined
"one by one" Hello World, so pipelining is responsible for the ~40× gap.

## Architecture

- **Concurrency model:** Single-threaded **event loop per process**, prefork
  **process-per-core**. `app.run('0.0.0.0', 8080, cores=multiprocessing.cpu_count())`
  spawns one process per logical CPU (`research-sources/01-mrhttp/app.py:17`). No
  threads, no coroutine pool for the hot path — the C `Protocol` object is an
  asyncio protocol whose callbacks (`Protocol_data_received`, `connection_made`,
  `connection_lost`, `eof_received`) are invoked by the loop (upstream
  `src/mrhttp/internals/protocol.c`).
- **I/O mechanism:** **epoll via libuv**, indirectly. The stack is asyncio +
  **uvloop 0.19.0** (`research-sources/01-mrhttp/requirements.txt:6`), which
  replaces asyncio's selector loop with libuv. This is a **readiness** model
  (epoll), not completion (io_uring). mrhttp does not implement its own epoll
  loop — it plugs a C protocol into uvloop's transport, so reads/writes go
  through uvloop's buffered transport `write()` rather than raw `writev`.
- **Worker/process model:** Prefork, **one process per logical core**, each
  running its own uvloop instance and accepting on the shared listener. (TFB runs
  this in a container per the Dockerfile, `CMD python3 app.py`,
  `research-sources/01-mrhttp/mrhttp.dockerfile:12`.) The vendored entry does not
  show an explicit `SO_REUSEPORT` flag; load distribution across the per-core
  processes is handled by the accept path / kernel. (Mechanism upstream-derived;
  the vendored source only shows `cores=cpu_count()`.)
- **HTTP parser:** **Custom hand-written C parser** (`mr_parse_request` in
  upstream `src/mrhttp/internals/parser.c`), *not* picohttpparser and *not*
  generated. The decisive feature is its **pipelining loop**: after parsing one
  request and firing the `Protocol_on_headers` / `Protocol_on_body` callbacks, it
  checks whether unconsumed bytes remain in the same received buffer and, if so,
  resets and re-parses in place:
  ```c
  parse_headers:
    /* ... parse one request, fire on_headers/on_body ... */
    if ( self->start < self->end ) {
      _reset(self, false);
      goto parse_headers;
    }
  ```
  So N pipelined requests delivered in a single `recv` are parsed in one C call
  with zero re-entry into Python's loop between them. (Upstream-derived from
  `parser.c`.) The build compiles with `-msse4.2 -mavx2 -mbmi2`
  (upstream `setup.py`), i.e. the parser is written to exploit SIMD/bit-manipulation
  for scanning.

## Performance techniques (catalog)

- **HTTP pipelining (the dominant lever).** The C parser loops over every
  pipelined request in a single received buffer (`goto parse_headers` while
  `start < end`, upstream `parser.c`). TFB's plaintext load *is* pipelined, so
  this is why mrhttp tops the chart (28.4M) while its own non-pipelined Hello
  World is ~708K (upstream README). **Evidence:** upstream
  `src/mrhttp/internals/parser.c`; README pipelined-vs-one-by-one numbers.
- **Response caching / precomputation.** The plaintext route is registered with
  `options=['cache']` (`research-sources/01-mrhttp/app.py:12`). Upstream README
  reports "cached Hello World" 8.5M vs "Hello World" 6.8M (~1.2×) — a precomposed
  response (status line + headers + body assembled once) served on cache hits
  instead of rebuilt per request. **Evidence:** `app.py:12`; upstream README.
- **Per-request object pooling / buffer reuse (near zero-alloc steady state).**
  The protocol pulls request objects from an app-level pool
  (`MrhttpApp_get_request`) rather than allocating per request, and writes
  responses into a reused response buffer (`getResponseBuffer(headerLen + rlen)`)
  — so the steady-state hot path does little or no `malloc`. **Evidence:**
  upstream `src/mrhttp/internals/protocol.c` (function names `MrhttpApp_get_request`,
  `getResponseBuffer`).
- **Whole hot path in C, Python only for registration.** `app.py` is trivial
  (two route decorators + `app.run`); all parsing, routing, response assembly,
  and the data-received callback are C (`mrhttp.internals` extension built from 17
  C files incl. `protocol.c`, `parser.c`, `response.c`, `router.c`). This
  eliminates per-request Python bytecode from the steady state. **Evidence:**
  `research-sources/01-mrhttp/app.py`; upstream `setup.py` (extension source list).
- **SIMD-oriented build.** `extra_compile_args = ['-msse4.2','-mavx2','-mbmi2',
  '-std=gnu99', ...]` (upstream `setup.py`). Enables vectorized/bit-manip scanning
  in the parser. Note: **no explicit `-O3` or `-march=native`** in `setup.py` — it
  relies on the distutils/pip default (`-O2`), so the win is from the targeted
  ISA-extension flags plus hand-written C, not aggressive global optimization.
  **Evidence:** upstream `setup.py`.
- **Own C JSON (not in plaintext path).** Uses `mrjson` (the author's C JSON lib,
  `requirements.txt:2`, `app.py:4`) for the `/json` test. Irrelevant to plaintext
  but part of the same "everything in C" philosophy. **Evidence:**
  `requirements.txt`, `app.py`.
- **Syscall amortization is *implicit* via pipelining, not via writev/sendmmsg.**
  mrhttp does not batch writes with `writev`/`sendmmsg` in the parser/protocol;
  amortization comes from (a) pipelining many requests per `recv` and (b) handing
  responses to uvloop's buffered transport, which coalesces writes at the libuv
  layer. There is **no io_uring, no SQPOLL, no registered buffers, no kernel
  bypass**. (Upstream-derived from `protocol.c` writing via `self->write`/transport.)

> **Caveat on the headline number.** TechEmpower issue #9055 ("mrhttp: a project
> with many problems") flags that mrhttp's plaintext result leans heavily on the
> `cache` option and pipelining, and questions how representative it is. Treat
> 28.4M as a best-case pipelined+cached figure, not steady-state per-request
> throughput. (Upstream-derived, TFB issue tracker.)

## What's reusable for jai-http

- **HTTP pipelining + parse-loop over one buffer — (b) portable, HIGHEST
  leverage.** This is the single biggest gap between jai-http (~1.8M) and the TFB
  leaders (~28M), and it maps cleanly onto our design. jai-http already has a
  **zero-copy incremental parser** producing string views into the connection
  read buffer; the change is to **loop the parser** over the read buffer:
  keep parsing → dispatching → appending the response while unconsumed bytes
  remain, instead of one request per `recv`. mrhttp's `goto parse_headers; if
  (start < end) reset, goto` is exactly the structure to emulate. This costs no
  new syscalls and reuses our existing parser and Pool.
- **Response coalescing for pipelined batches — (b) portable, HIGH leverage,
  pairs with the above.** Once we parse N requests from one buffer, we should
  **accumulate all N responses into a single buffer and emit one `writev`** rather
  than one `writev` per request. jai-http already builds the response header in
  the per-request Pool and sends with a single `writev([headers, body])` — extend
  that to append `[hdr0,body0,hdr1,body1,…]` for the whole batch and flush once.
  This turns N writes into 1, which is where most of the pipelined throughput
  comes from. (mrhttp gets the equivalent coalescing "for free" from uvloop's
  buffered transport; we'd do it explicitly in our writev path.)
- **Precomputed / cached response (`options=['cache']`) — (b) portable, MEDIUM-HIGH
  leverage.** For a static body (the plaintext route), precompose the *entire*
  response once — status line + all fixed headers + `Content-Length` + body — into
  a constant buffer and `writev` it directly, skipping per-request header
  formatting. jai-http already avoids the `tprint` temp-storage trap by formatting
  through the Pool; a precomposed-constant fast path for cacheable routes removes
  even that. ~1.2× in mrhttp's own numbers.
- **Date-header caching — (b) portable, MEDIUM leverage, currently a jai-http
  gap.** mrhttp doesn't visibly do per-second Date caching in `protocol.c`, but
  it's the standard companion to precomposed responses and is on jai-http's
  known TODO list (Date-header caching). Compute the RFC1123 Date string once per
  second (or per epoll batch) on each shared-nothing worker and splice the cached
  bytes in — avoids `strftime`/formatting per response. Our datetime module
  already has the formatting primitives.
- **Per-request object/buffer pooling — (a) jai-http already does this.** mrhttp's
  `MrhttpApp_get_request` / `getResponseBuffer` reuse is conceptually our
  **per-request Pool** (reset between requests) plus the per-connection read
  buffer. No action needed; we already have the zero-alloc-steady-state property
  mrhttp relies on.
- **Process-per-core prefork — (a) jai-http already does this.** mrhttp's
  `cores=cpu_count()` per-core processes are our **N shared-nothing SO_REUSEPORT
  workers**. Our model is actually *stronger* (explicit `SO_REUSEPORT` per worker
  + own epoll instance, true shared-nothing). No action.
- **SIMD parser scanning (`-msse4.2/-mavx2/-mbmi2`) — (c) portable, LOWER
  leverage.** Vectorized header/line scanning is a real win but secondary to
  pipelining, and Jai would need explicit SIMD intrinsics (Machine_X64) or
  `-march`-style codegen tuning. Defer until after pipelining + coalescing.
- **uvloop / libuv transport — (d) not portable / not desirable.** mrhttp inherits
  epoll + write-coalescing from libuv. jai-http already owns its epoll loop
  directly (edge-triggered, per-worker), which is the better foundation — we want
  to add explicit coalescing, not adopt a libuv-style abstraction layer.
- **CPU affinity pinning — not exhibited by mrhttp** (it relies on the scheduler),
  and a known jai-http gap. Orthogonal to the mrhttp techniques; worth doing
  independently on the 64-thread Threadripper but not learned from this entry.

**Highest-leverage takeaways for jai-http:**
1. **Implement HTTP pipelining:** loop the existing zero-copy parser over the
   whole connection read buffer (parse → dispatch → append response while bytes
   remain), exactly like mrhttp's `goto parse_headers` loop. This is the one
   change that closes most of the 1.8M → 28M gap on the TFB plaintext workload.
2. **Coalesce the pipelined batch into a single `writev`:** accumulate all
   responses for one read into one buffer and emit one syscall, instead of one
   `writev` per request.
3. **Precompose cacheable static responses** (full status+headers+body, plus a
   per-second cached Date header) and `writev` the constant directly — eliminates
   per-request header formatting on hot static routes.

## Sources
- Vendored: `research-sources/01-mrhttp/app.py`, `research-sources/01-mrhttp/requirements.txt`,
  `research-sources/01-mrhttp/mrhttp.dockerfile`, `research-sources/01-mrhttp/README.md`,
  `research-sources/01-mrhttp/config.toml`, `research-sources/01-mrhttp/benchmark_config.json`
- Upstream: https://github.com/MarkReedZ/mrhttp (README — pipelined vs one-by-one numbers, cached variant),
  https://raw.githubusercontent.com/MarkReedZ/mrhttp/master/src/mrhttp/internals/parser.c (`mr_parse_request`, `goto parse_headers` pipelining loop),
  https://raw.githubusercontent.com/MarkReedZ/mrhttp/master/src/mrhttp/internals/protocol.c (asyncio `Protocol_data_received`, `MrhttpApp_get_request`, `getResponseBuffer`),
  https://raw.githubusercontent.com/MarkReedZ/mrhttp/master/setup.py (17-file C extension, `-msse4.2 -mavx2 -mbmi2`, no `-O3`/`-march`),
  https://github.com/TechEmpower/FrameworkBenchmarks/issues/9055 (cache/pipelining caveat on the headline number)
