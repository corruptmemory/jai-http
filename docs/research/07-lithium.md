# lithium — TechEmpower r23 Plaintext #7 (27,953,333 req/s)

## Summary

lithium is a modern C++17 asynchronous web framework by Matthieu Garrigues whose HTTP backend
is an epoll + boost::context fiber (stackful coroutine) reactor. Each connection runs as a
fiber that yields to the reactor on `EAGAIN` and is resumed on epoll readiness, so the
handler reads like blocking code while the I/O is fully non-blocking. Its speed comes from a
thread-per-core, shared-nothing reactor with SO_REUSEPORT, a precomputed double-buffered
top-header (status line + `Server` + `Date`) refreshed once per second, per-request response
*accumulation* that coalesces all pipelined responses from one read batch into a single
flush, and heavy template metaprogramming that bakes routing and JSON/SQL shapes into types at
compile time. Built with `clang++ -O3 -march=native -flto` plus a two-pass PGO (profile-guided
optimization) step.

## Architecture

- **Concurrency model:** Thread-per-core reactor, one `std::thread` per
  `std::thread::hardware_concurrency()` (`int nthreads = nprocs;` —
  `research-sources/07-lithium/lithium.cc:92-98`, passed as `s::nthreads = nthreads` to
  `http_serve`, `lithium.cc:238`). Each thread owns an `async_reactor` with its **own epoll
  instance**. Per *connection*, work runs inside a **boost::context stackful fiber**
  (`boost::context::callcc(...)`, `fiber = fiber.resume()`); the handler signature
  `[&](http_request& request, http_response& response)` is fiber code, and DB calls suspend the
  fiber on `request.fiber` (`lithium.cc:147`, `random_numbers.connect(request.fiber)`). Linked
  against `-lboost_context` (`research-sources/07-lithium/compile.sh:23`). Confirmed upstream in
  `libraries/http_server/http_server/tcp_server.hh`.
- **I/O mechanism:** epoll, **edge-triggered**. Listener registered with `EPOLLIN | EPOLLET`
  under `#ifdef __linux__` (upstream `tcp_server.hh`). Readiness-driven: a fiber that gets
  `EAGAIN`/`EWOULDBLOCK` yields back to the reactor and is resumed when epoll reports the fd
  ready. **No io_uring** — pure epoll. (Windows path uses wepoll without `EPOLLET`.)
- **Worker/process model:** Single process, multiple threads. **SO_REUSEPORT is set**
  (`setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, ...)` under `#if __linux__`, upstream
  `tcp_server.hh`) so the kernel load-balances accepts across the per-thread reactors —
  shared-nothing, no cross-thread handoff. **No CPU pinning / `sched_setaffinity`** in the
  codebase (relies on the OS scheduler). Thread count = logical core count.
- **HTTP parser:** Custom, hand-written zero-copy parser operating on the connection's
  `input_buffer` (upstream `libraries/http_server/http_server/`). Pipelining is handled by the
  read/dispatch loop: the reactor reads everything available, then runs the handler once per
  parsed request, *accumulating each response into the same per-connection `output_buffer`*,
  and only flushes when the read buffer is drained — see Performance techniques below.

## Performance techniques (catalog)

- **Pipelining + response coalescing (the TFB plaintext win).** The dispatch loop is
  `handler(ctx); ctx.prepare_next_request(); if (rb.empty()) ctx.flush_responses();` (upstream
  `http_ctx.hh`). All requests sitting in one `read_more()` batch are handled back-to-back,
  each response appended to a single `output_buffer`, and the buffer is flushed **once** when
  the read buffer empties. TFB's plaintext test pipelines up to 16 requests per packet, so this
  collapses N responses into one `send()` — the dominant reason the plaintext number is ~28M.
- **Syscall amortization / batched writes.** Status line, headers, and body are written
  sequentially into one `output_buffer` (`format_top_headers(output_stream); output_stream <<
  "Content-Length: " << s.size() << "\r\n\r\n" << s;`, upstream `http_ctx.hh`) and sent with a
  single `flush()` per batch — one write syscall per pipeline batch, not per response.
- **Response precomputation + Date caching.** A double-buffered `http_top_header_builder`
  precomputes the entire `200 OK` top block —
  `"HTTP/1.1 200 OK\r\nServer: <name>\r\nDate: <...> GMT\r\n"` — as one contiguous string;
  `top_header_200()` returns it by view. The `Date` is rebuilt by `tick()` via
  `strftime("Date: %a, %d %b %Y %T GMT\r\n", ...)` into the inactive buffer, then the buffers
  are swapped (lock-free atomic access) — refreshed ~once per second, not per request (upstream
  `http_top_header_builder.hh`). The 200 fast path therefore emits a memcpy of a cached string
  plus only `Content-Length` + body.
- **Allocation / buffer reuse.** Per-connection `input_buffer` and `output_buffer` are reused
  across requests (zero-copy parsing reads views into the input buffer); steady state for
  plaintext is essentially allocation-free. `growing_output_buffer` is used only for the heavier
  fortunes path. boost::context fibers reuse their stacks across the connection's lifetime.
- **Compile-time metaprogramming (the lithium signature).** Routes are declared as
  `my_api.get("/plaintext") = [&](...){...}` and the API/router is assembled into a typed
  structure at compile time. The "symbol" system (`s::id`, `s::message`, … via the `LI_SYMBOL`
  macro, `research-sources/07-lithium/symbols.hh`) turns field names into distinct **types**, so
  metamaps (`mmm(s::id = int(), s::randomNumber = int())`, `lithium.cc:80`), JSON serialization
  (`response.write_json(s::message = "Hello, World!")`, `lithium.cc:143`), and the SQL ORM
  schema are all monomorphized — field iteration, JSON key emission, and SQL column binding
  become straight-line code with no runtime reflection, string lookups, or maps on the hot path.
- **Parser/serializer specialization.** Because shapes are types, JSON writing
  (`write_json`/`write_json_generator`) is generated per concrete metamap; there is no generic
  schema walk at request time.
- **Build flags (`research-sources/07-lithium/compile.sh`).** `clang++ -O3 -march=native -flto
  -std=c++17 -DNDEBUG`, plus **two-pass PGO**: first build with
  `-fprofile-instr-generate=./profile.prof -DPROFILE_MODE` runs an in-process `siege()` load
  (`http_benchmark_connect` / `http_benchmark`, `lithium.cc:51-62`), then
  `llvm-profdata merge` → rebuild with `-fprofile-instr-use=./profile.pgo`. Custom `Server`
  name shortened to `l` via `-DLITHIUM_SERVER_NAME=l` (smaller header bytes on the wire). Libs:
  `-lpthread -lboost_context -lssl -lcrypto`. For the DB tests, libpq itself is rebuilt
  `-O3 -march=native -flto` (`compile_libpq.sh:20`), and a batch variant
  (`lithium_batch.cc` + a libpq batch-mode patch) pipelines SQL with `end_of_batch()` /
  `flush_results()`.
- **Monothread/perf toggles.** `#if MONOTHREAD` forces `nthreads = 1`; `N_SQL_CONNECTIONS`
  controls async DB pool depth per thread — both compile-time switches, illustrating the
  "configure-by-constant" style.

## What's reusable for jai-http

- **(a) Already done.** SO_REUSEPORT shared-nothing per-worker epoll; per-worker own listen
  socket; edge-triggered epoll; zero-copy parser; per-request buffer reuse (Pool allocator);
  single-syscall response via `writev`. jai-http and lithium share the same skeleton — the gap
  is everything lithium does *on top* of it for pipelined throughput.
- **(b) Portable + HIGH leverage:**
  - **Pipelined response coalescing.** This is the biggest delta (jai-http "not yet doing
    pipelining/response coalescing"). lithium's loop — handle every request in the current read
    buffer, append each response to one output buffer, flush once when the read buffer drains —
    maps cleanly onto jai-http: keep parsing requests out of the connection read buffer in a
    loop, build each response into a per-connection (Pool-allocated) output buffer, and call one
    `writev` (or plain `write`) only when no full request remains. This turns N keep-alive/
    pipelined requests into one syscall and is the single largest lever for the plaintext-style
    workload.
  - **Precomputed + cached top header (incl. Date), Jai-specialized.** lithium precomputes the
    whole `HTTP/1.1 200 OK\r\nServer: …\r\nDate: …\r\n` block and refreshes only the Date once
    per second via a double buffer. jai-http currently formats headers per response. A
    once-per-second background (or epoll-timerfd) Date tick writing into a swapped buffer, plus
    a constant precomputed status+Server prefix, removes per-request `strftime`/formatting.
    **Compile-time-specialization angle (fits Jai directly):** Jai's `#run` / metaprogram can
    bake the constant header prefix (`HTTP/1.1 200 OK\r\nServer: jai-http\r\n`) into a compile-
    time string literal, and — like lithium's typed routes — a `#run`-generated dispatch can
    specialize the hot route's responder so the steady-state path is `copy(cached_top) +
    Content-Length + body` with no branching over a route table. This is the direct analog of
    lithium's C++ template monomorphization: where lithium uses templates + `LI_SYMBOL` types,
    jai-http uses `#run`/`#insert` to emit specialized per-route response writers at compile
    time.
  - **Compile-time route/response specialization generally.** lithium proves a metaprogrammed
    router has ≈0 runtime overhead because dispatch is resolved into types. jai-http already has
    the metaprogramming substrate (`first.jai`, `#code`/`#insert` used in the CSV module). A
    compile-time route table that generates a specialized matcher/dispatcher (radix or perfect-
    hash on method+path) is the same idea and addresses jai-http's known O(route-count) linear
    `dispatch` scan.
- **(c) Portable, lower leverage:**
  - **PGO build.** A profile-guided second pass (run a representative load, feed the profile
    back) is a generic win; whether Jai's backend exposes instrumentation-based PGO is the open
    question — lower priority than coalescing.
  - **`-march=native` / native-arch codegen** for the release build (already in the spirit of
    jai-http's `-release`). Shorter `Server` name to trim wire bytes is trivially portable.
- **(d) C++-specific:** boost::context stackful fibers as the per-connection concurrency model
  (jai-http's event-loop-state-machine + Pool model is a deliberate, simpler alternative —
  adopting fibers would be a large architectural change, not a tweak); template/`LI_SYMBOL`
  type-level field encoding (Jai achieves the equivalent via `#run`/`#insert`, not C++
  templates); libpq batch-mode patch (DB-path only, irrelevant to plaintext).

**Highest-leverage takeaways for jai-http:**
1. **Implement pipelined response coalescing** — handle all requests in a read batch and flush
   one buffer with a single `writev`. This is the top-leaders' plaintext trick and jai-http's
   biggest missing piece.
2. **Precompute and cache the top header + Date** (once-per-second tick, double-buffered), and
   use Jai's `#run` to bake the constant status/`Server` prefix at compile time — the direct
   Jai analog of lithium's template-specialized 200 fast path.
3. **Compile-time-specialize routing** with a `#run`-generated dispatch table to kill the
   current O(route-count) linear scan, mirroring lithium's zero-overhead typed router.

## Sources

- Vendored: `research-sources/07-lithium/lithium.cc`, `lithium_batch.cc`, `symbols.hh`,
  `compile.sh`, `compile-batch.sh`, `compile_libpq.sh`, `README.md`, `config.toml`,
  `benchmark_config.json`, `lithium.dockerfile`, `lithium-postgres*.dockerfile`.
- Upstream (github.com/matt-42/lithium, `master`):
  `libraries/http_server/http_server/tcp_server.hh` (epoll/EPOLLET, SO_REUSEPORT, per-thread
  reactor, boost::context fibers, no CPU pinning);
  `libraries/http_server/http_server/http_top_header_builder.hh` (double-buffered precomputed
  top header + `strftime` Date `tick()`);
  `libraries/http_server/http_server/http_ctx.hh` (`format_top_headers`, single-buffer
  Content-Length+body write, flush-when-read-buffer-empty coalescing loop).
