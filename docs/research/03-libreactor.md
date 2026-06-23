# libreactor — TechEmpower r23 Plaintext #3 & #8 (28,025,992 / 27,943,940 req/s)

## Summary

libreactor is a single-binary C HTTP server built on Fredrik Widlund's reactor framework
(`libreactor` + `libdynamic` + `libclo`). Its one-line reason for speed: an **edge-triggered**
(in practice level-triggered, see Architecture) epoll reactor with **one prefork worker process
pinned per CPU core via SO_REUSEPORT + CBPF steering**, a **zero-copy picohttpparser** front end,
and a hot path that **coalesces every pipelined request's response into one growable output buffer
flushed with a single `send()`** — so under TechEmpower's 16-deep pipelined plaintext load each
syscall amortizes across ~16 requests.

The two slots differ only in the *response-construction* path, not the engine:
- **#3 "Platform"** (`src/libreactor.c` + `src/helpers.c`): hand-rolled response writer that memcpys a
  precomputed status-line/`Server`/`Content-Type` preamble, a **per-thread cached `Date` header**,
  and a length-formatted `Content-Length` directly into the stream's output buffer. Also installs
  `SO_ATTACH_REUSEPORT_CBPF` to steer connections to the worker on the same CPU.
- **#8 "Micro"** (`src/libreactor-server.c`): same handler logic but builds responses through
  libreactor's stock `server_ok()` API and does **not** install the CBPF steering filter. Slightly
  slower (27.94M vs 28.03M) — the delta is the generic `server_ok` path and the missing CPU-affinity
  packet steering.

## Architecture

- **Concurrency model:** Single-threaded **reactor per process**, one process **prefork per online
  CPU**. `fork_workers()` (`src/helpers.c:97-171`) reads `sched_getaffinity`, forks
  `num_online_cpus` children, and `sched_setaffinity`-pins each child to a distinct core
  (`src/helpers.c:155-159`). No threads, no shared mutable state between workers — pure
  shared-nothing, same shape as jai-http but process-per-core instead of thread-per-core. Forking is
  serialized through a per-child `eventfd` semaphore (`src/helpers.c:132,144,59-60`) so the kernel
  sees workers register their reuseport sockets in deterministic order — required for CBPF steering
  to map cpu→socket cleanly.

- **I/O mechanism:** Linux **epoll**, readiness-based. The reactor core (`core_loop`, upstream
  `src/reactor/...`) drives `epoll_wait`. fds are registered via `core_add(..., EPOLLIN)` with
  **no `EPOLLET`** flag (upstream `src/reactor/notify.c`, confirmed pattern) — i.e. **level-triggered**
  for read readiness; `EPOLLOUT` is added on demand only when an output buffer can't fully drain
  (partial-write backpressure, upstream `src/reactor/stream.c` `stream_notify`). No io_uring. The
  read path does a `recv(... STREAM_BLOCK_SIZE ...)` loop into a growable `libdynamic` buffer until a
  short read (upstream `stream.c` `stream_receive`).

- **Worker/process model:** **SO_REUSEPORT** per-worker listen socket (`server_open(&s, 0, 8080)`,
  `src/libreactor.c:55`), one worker per core, each pinned. The #3 config additionally attaches a
  **CBPF reuseport filter** (`enable_reuseport_cbpf`, `src/helpers.c:86-95`) whose BPF program
  returns `SKF_AD_CPU` — the kernel hashes the *arriving CPU* to the matching reuseport socket, so a
  connection's packets, its accepting worker, and its epoll processing all stay on one core
  (cache-local, no cross-core migration). This is the single biggest structural difference from
  jai-http, which relies on the kernel's default reuseport hash with no CPU pinning.

- **HTTP parser:** **picohttpparser** (`src/picohttpparser/picohttpparser.c`), wrapped by upstream
  `http_request_read` → `phr_parse_request(...)`. **Zero-copy**: method/target/headers are returned
  as pointers + lengths into the input buffer, no allocation (confirmed upstream `http.c`). Return
  contract: `>0` = bytes consumed for a complete request, `0` (`-2` remapped) = need more data, `-1` =
  malformed. **Pipelining is the heart of the plaintext win.** Upstream `server.c`'s session-read
  loop is:
  ```c
  for (offset = 0; offset < data.size; offset += n) {
    n = http_request_read(&context.request, segment_offset(data, offset));
    if (n == 0) break;          // incomplete tail request → stop
    if (n == -1) return CORE_ABORT;
    e = core_dispatch(&session->server->user, SERVER_REQUEST, (uintptr_t)&context);
  }
  stream_flush(&session->stream);     // ONE send() for all responses
  stream_consume(&session->stream, offset);
  ```
  Every parsed request runs the user handler, which **appends** its response into the *same*
  `stream` output buffer (never sends). Only after the whole read buffer is drained does
  `stream_flush` emit one `send()` carrying all N coalesced responses. With wrk piping 16 requests
  per connection, that's ~16 responses per syscall.

## Performance techniques (catalog)

- **HTTP pipelining & response coalescing (THE key technique for this test).** The session loop
  parses *all* requests sitting in one `recv` buffer and the handler appends each response to one
  output buffer; a single `stream_flush` → single `send()` ships them together (upstream
  `server.c` loop above; append happens in `write_response`,
  `research-sources/03-libreactor/src/helpers.c:54-69`, via `stream_allocate` + `memcpy`). This is
  exactly what drives 28M req/s vs jai-http's ~1.8M: syscalls and epoll wakeups are amortized across
  the whole pipeline depth instead of one-per-request.

- **Syscall amortization.** One `recv` pulls many requests; one `send` pushes many responses
  (upstream `stream_receive` / `stream_send`). `write_response` does **not** call writev or send — it
  only `memcpy`s into the buffer (`helpers.c:62-68`); the actual write is deferred to the per-batch
  flush. (Contrast jai-http: one `writev` *per request*.)

- **Zero-allocation steady state / buffer reuse.** `stream_allocate(stream, response_size)` resizes
  the worker's persistent output buffer and returns a write pointer
  (`helpers.c:62`, upstream `stream.c`); the `libdynamic` buffer is reused across requests and only
  grows, never per-request malloc/free. The input buffer is likewise a persistent growable buffer
  consumed via `stream_consume`. No per-request allocator needed at all — the buffers *are* the
  arena.

- **Response precomputation.** Status line + `Server:` + `Content-Type:` are compile-time string
  literals memcpy'd verbatim: `JSON_PREAMBLE` / `TEXT_PREAMBLE` (`helpers.c:20-26`), stored as static
  `segment`s with `sizeof-1` lengths (`helpers.c:73,79`). The plaintext/json bodies are also static
  (`libreactor.c:17-20`). Nothing in the static parts is formatted at request time.

- **Date header caching.** `http_date_header()` keeps a **per-thread** `__thread` 38-byte buffer
  pre-seeded with the fixed `Date: ... GMT\r\n` skeleton and only memcpys the 29 volatile date bytes
  in at offset 6 (`helpers.c:30-37`). `http_date(0)` is libreactor's once-per-second-cached clock, so
  the formatted date string is reused across all requests in that second — no `gmtime`/`strftime` on
  the hot path. (jai-http currently has no Date header at all.)

- **Branchless integer formatting for Content-Length.** `http_content_length_header` uses
  `utility_u32_len` + `utility_u32_sprint` into a per-thread static buffer and appends the
  header-terminating `\r\n\r\n` in the same shot (`helpers.c:41-52`) — no `snprintf`.

- **CPU affinity / core pinning + CBPF connection steering.** Each worker pinned to one core
  (`helpers.c:155-159`); `SO_ATTACH_REUSEPORT_CBPF` with an `SKF_AD_CPU` BPF program routes each
  connection to the reuseport socket on its own CPU (`helpers.c:86-95`). Keeps connection state, its
  socket buffers, and its epoll loop cache-resident on one core. **#3 only**; #8 omits it.

- **Parser specialization.** picohttpparser is a hand-tuned, SIMD-friendly (SSE4.2 token scanning when
  available), zero-copy request parser — far cheaper per byte than a generic state machine, and it
  reports exact bytes consumed so the pipeline loop can advance precisely.

- **Build flags (aggressive).** `Makefile:4`:
  `-std=gnu11 -O3 -g -march=native -flto`. So: **-O3, native ISA targeting (`-march=native`, enables
  SSE4.2/AVX for picohttpparser and memcpy), and link-time optimization (`-flto`)** across the app
  objects. The deps are built the same way — both `libdynamic` and `libreactor` ship `-march=native`,
  and the dockerfiles add `CFLAGS="-march=native"` to the `libclo` build
  (`libreactor.dockerfile:23`, comment at `:18`). Built with **gcc-10** (`libreactor.dockerfile:8`).
  **No jemalloc / tcmalloc** — there is effectively no malloc on the hot path, so a custom allocator
  buys nothing.

- **Tiny `Server` header.** `Server: L\r\n` (`helpers.c:21,25`) — one byte of server name to shave
  response bytes (every byte counts at 28M resp/s; smaller responses = more fit per TCP segment).

- **`SIGPIPE` ignored** (`helpers.c:104`) so a peer close mid-write doesn't kill the worker.

## What's reusable for jai-http

libreactor is our closest architectural analogue — a shared-nothing epoll reactor in C — so the
mapping is unusually direct. Per technique:

- **(b) HIGH leverage — HTTP/1.1 pipelining + response coalescing.** *This is the gap that explains
  the 28M-vs-1.8M gulf on the pipelined plaintext test*, and it maps cleanly onto jai-http's loop.
  Today jai-http parses one request and issues one `writev` per request. To match libreactor: after a
  `recv` fills the connection read buffer, **loop the zero-copy parser over the buffer** — for each
  complete request, run the handler and **append** its serialized response into a per-connection
  output buffer (don't send yet); stop at the first incomplete request; then issue **one** `writev`/
  `send` of the whole accumulated output buffer and `consume` the parsed prefix. jai-http already has
  a zero-copy incremental parser and a per-request Pool — the changes are (1) make the parser loop
  until "need more bytes," (2) move the response sink from per-request writev to an
  append-to-output-buffer + single flush, (3) carry leftover partial-request bytes across reads. This
  is the single highest-value change and it reuses machinery we already have.

- **(b) HIGH leverage — precomputed preambles + cached Date header.** Directly portable: store the
  `HTTP/1.1 200 OK\r\nServer: ...\r\nContent-Type: ...\r\n` prefix as a compile-time constant byte
  slice (Jai `#run`/static), and keep a per-worker Date buffer refreshed at most once/second
  (jai-http's `datetime` module already formats RFC1123-style; format it once per second in the
  worker, memcpy the 29 volatile bytes). jai-http currently emits **no** Date header — adding it the
  *cheap* way (cached, not per-request formatted) is both a correctness/HTTP-compliance win and avoids
  a per-request format cost. Pairs naturally with the coalescing change since both write into the
  output buffer.

- **(b) HIGH leverage — CPU affinity + reuseport CBPF steering.** jai-http already does SO_REUSEPORT
  shared-nothing workers but does **not** pin them or steer connections. Two concrete additions:
  (1) `sched_setaffinity` each worker thread to a distinct core (trivial via the Linux module), and
  (2) attach the same `SO_ATTACH_REUSEPORT_CBPF` `SKF_AD_CPU` BPF program to the listen socket so the
  kernel routes each connection to the worker on its arriving CPU. On the 64-thread Threadripper
  target this keeps connection + epoll + socket buffers core-local and removes cross-core cacheline
  bouncing — libreactor's data shows it's worth a measurable few percent (#3 vs #8). Note: jai-http is
  *thread*-per-core not *process*-per-core, so the deterministic-fork eventfd dance (`helpers.c` fork
  ordering) isn't needed — but the CBPF attach + per-thread pin is.

- **(a) Already done.** SO_REUSEPORT shared-nothing workers; epoll; zero-copy incremental parser;
  single-syscall send of a response (jai-http uses `writev` — equivalent for one response; the upgrade
  is making it one syscall per *batch*, see coalescing above). Static/precomputed body bytes.

- **(c) Lower leverage — zero-alloc via persistent buffers.** libreactor avoids any per-request
  allocator by reusing one growable input + one growable output buffer per connection. jai-http's
  per-request Pool is already cheap (reset, not free), so swapping to libdynamic-style persistent
  buffers is a refinement, not a step-change — though if jai-http adopts response coalescing it will
  *need* a persistent per-connection output buffer anyway, at which point this falls out for free.

- **(c) Lower leverage — branchless `Content-Length` / int formatting.** Worth doing as part of the
  response-writer rewrite (small per-request win), but dominated by the coalescing change.

- **(d) Not portable / not worth it.** Process-prefork model and the eventfd-serialized fork ordering
  are libreactor's answer to thread-per-core in C; jai-http's thread model is fine — skip. jemalloc:
  irrelevant (no hot-path malloc). picohttpparser's SSE4.2 token scan is a parser-internal
  optimization jai-http could *emulate* but only after the structural wins above land.

**Highest-leverage takeaways for jai-http:**
1. **Implement HTTP/1.1 pipelining with response coalescing** — loop the parser over the whole read
   buffer, append each response into one per-connection output buffer, and flush with a single
   `writev`/`send` per batch. This is *the* technique behind 28M req/s and the largest single win
   available to us on the pipelined plaintext benchmark.
2. **Add a per-worker cached Date header + precomputed status/Content-Type preamble**, formatted at
   most once per second and memcpy'd — cheap, HTTP-correct, and a natural companion to the output
   buffer.
3. **Pin each worker to a core and attach the `SO_ATTACH_REUSEPORT_CBPF` (`SKF_AD_CPU`) steering
   filter** so connections stay core-local on the 64-thread Threadripper.

## Sources

- Vendored:
  - `research-sources/03-libreactor/src/libreactor.c:15-64` (#3 handler, `server_open`,
    `enable_reuseport_cbpf`, `core_loop`)
  - `research-sources/03-libreactor/src/libreactor-server.c:15-65` (#8 handler via `server_ok`, no
    CBPF)
  - `research-sources/03-libreactor/src/helpers.c:20-26` (precomputed preambles), `:30-37` (cached
    `__thread` Date header), `:41-52` (branchless Content-Length), `:54-69` (`write_response` =
    `stream_allocate` + memcpy, no send), `:71-84` (plaintext/json appenders), `:86-95`
    (`enable_reuseport_cbpf` / `SKF_AD_CPU`), `:97-171` (`fork_workers`, per-core pin, eventfd fork
    ordering)
  - `research-sources/03-libreactor/src/helpers.h:1-13`
  - `research-sources/03-libreactor/Makefile:4` (`-O3 -march=native -flto`)
  - `research-sources/03-libreactor/libreactor.dockerfile:8,18,23,26-31` (gcc-10, march=native deps,
    pinned libreactor `63fa717a8047` release-2.0)
  - `research-sources/03-libreactor/config.toml` / `benchmark_config.json` (Platform vs Micro
    classification)
- Upstream (pinned commit `63fa717a8047`, branch `release-2.0`):
  - https://github.com/fredrikwidlund/libreactor — `src/reactor/server.c` (pipelined session-read
    loop: parse-all → dispatch-each → single `stream_flush`)
  - `src/reactor/stream.c` (`stream_receive` recv-loop, `stream_allocate`, `stream_send` single send,
    `EPOLLOUT` backpressure)
  - `src/reactor/notify.c` (epoll registration via `core_add(..., EPOLLIN)`, no `EPOLLET`)
  - `src/reactor/http.c` + `src/picohttpparser/picohttpparser.c` (zero-copy `phr_parse_request`)
