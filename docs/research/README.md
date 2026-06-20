# TechEmpower r23 Plaintext top-10 — technique synthesis

Research into how the TFB plaintext leaders reach ~28M req/s (~18× nginx, ~15×
our current ~1.8M). Vendored sources: [`research-sources/`](../../research-sources/).
Per-candidate reports linked below. **Read this first; it's the decision doc.**

## The one finding

**Every single top-10 entry wins the same way: HTTP/1.1 pipelining with response
coalescing.** TFB's plaintext test sends ~16 pipelined requests per connection.
The leaders all do the identical loop:

1. One `recv` drains *all* pipelined requests sitting in the connection buffer.
2. The parser loops over the buffer; each request's response is **appended** into
   one per-connection output buffer (nothing is sent yet).
3. When the buffer holds no further complete request, **one** `write`/`writev`
   flushes the whole batch.

This collapses ~16 `recv`+`send` syscall pairs into ~1 + ~1 — roughly a 16×
reduction in per-request syscall and loop overhead. **That ratio is essentially
the entire 1.8M → 28M gap.** It is not io_uring, not kernel bypass, not a faster
language — it's batching.

> **jai-http already has every primitive this needs** — zero-copy parser,
> per-request Pool, single-`writev` send, SO_REUSEPORT workers. We just process
> **one request per `recv` and `writev` per request.** Closing the gap is a
> dispatch-loop change, not a rewrite.

## io_uring myth-buster

A standing assumption was that the top of the chart requires io_uring. **It does
not.** faf (#2), libreactor (#3/#8), uSockets behind uWebSockets.js (#5), lithium
(#7), may (#9), silverlining (#6, Go netpoller), and Kestrel (#10) **all run on
plain epoll.** io_uring is opt-in in uSockets and *disabled* in the benchmark
image; upstream pegs its network-I/O win at typically <5–10% over a tuned epoll
loop. **Pipelining is the lever; io_uring is a rounding error by comparison.**

## Cross-cutting technique matrix

| Technique | mrhttp | faf | libreactor | pico.v | uWS.js | silver­lining | lithium | may | aspnet-aot |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **Pipelining + response coalescing** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Cached `Date` header (1/sec) | – | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Precomputed static response prefix | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Zero-alloc steady state (arena/pool) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| SO_REUSEPORT shared-nothing per core | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | (rt) | ✱ |
| CPU pinning per worker | (uvloop) | ✅ | ✅(#3) | ✅ | – | – | – | – | – |
| **CBPF `SKF_AD_CPU` conn steering** | – | ✅ | ✅(#3) | – | – | – | – | – | – |
| `-march/target-cpu=native` + SIMD parse | ✅ | ✅ | ✅ | ✅ | (C++) | ✅ | ✅ | ✅ | (AOT) |
| LTO / PGO | – | LTO | LTO | LTO | – | – | **PGO** | LTO | TieredPGO |
| Compile-time response/route specialization | (C) | ✅ | – | – | – | – | ✅ | – | (srcgen) |
| io_uring | ❌ | ❌ | ❌ | ❌ | off | ❌ | ❌ | ❌ | ❌ |

✱ aspnetcore-aot's default Sockets transport uses a single accept path with N IO
queues, not SO_REUSEPORT (the reuseport transport is a separate experimental one).

## What jai-http already does (our baseline)

- ✅ SO_REUSEPORT shared-nothing workers (matches everyone)
- ✅ Per-request Pool / zero-alloc steady state (matches the arena pattern; we have
  no GC, so silverlining/may's GC-avoidance work is structurally free for us)
- ✅ Zero-copy incremental parser (matches libreactor/picohttpparser style)
- ✅ Single `writev` per response (but per-*request*, not per-*batch* — the gap)

## Prioritized options for jai-http (review these)

Ordered by leverage-per-effort. Items 1–3 are where the leaders actually live.

1. **HTTP/1.1 pipelining + response coalescing** — *the* win. Loop the existing
   zero-copy parser over the whole read buffer; append each response into a
   per-connection output buffer; carry any partial-request tail to the next read;
   emit one `writev` per batch; move the Pool reset from per-request to per-batch.
   Maps directly onto current code. **Closes most of the 1.8M → 28M gap on this
   workload.**
2. **Cached `Date` header** — format once/second on a background thread, `memcpy`
   the 29 bytes per response. Near-free; we already have a datetime module. Every
   leader does this.
3. **Precomputed static response prefix via Jai compile-time** — bake the constant
   `HTTP/1.1 200 OK\r\nServer: …\r\nContent-Type: …` block with `#run`/`#insert`,
   and (à la lithium's `LI_SYMBOL`/aspnetcore's source-gen) specialize a per-route
   responder at compile time. This is the **Jai-native angle** — our metaprogramming
   is the direct analog of lithium's C++ template monomorphization.
4. **CPU pinning + `SO_ATTACH_REUSEPORT_CBPF` (`SKF_AD_CPU`) connection steering** —
   faf and libreactor #3 pin each worker to a core and install a tiny BPF program so
   the kernel routes each connection to the worker on the core it arrived on. This
   is exactly the `SO_INCOMING_CPU`/flow-steering lever flagged against our observed
   idle-at-peak headroom — and the measured difference between libreactor #3 (with
   it) and #8 (without) on the same engine. **Most relevant on the 64-core
   Threadripper.**
5. **`-march=native` in `-release` + SIMD parser scanning** — unlock the
   `PCMPESTRI`/SWAR delimiter-scan trick picohttpparser uses; ensure release builds
   target the host microarch so SIMD is actually emitted.

**Not worth it now:** io_uring (see myth-buster — <5–10%, and every leader skips
it); a coroutine runtime (may/lithium use fibers, but that's a means to make
batching *natural*, which we can do directly in our epoll loop).

## Important caveat — what this benchmark does and doesn't predict

These numbers are **pipelined plaintext**, a syscall-amortization drag race.
Pipelining (#1) is worth ~16× *here* but only helps clients that actually pipeline
— real browsers/htmx mostly don't, so it benefits the leaderboard far more than our
weather-station target. **But #2–#5 (Date caching, precomputed responses,
affinity/steering, `-march=native`) help every workload**, pipelined or not. The
honest framing: pipelining wins the TFB plaintext title; the others win real req/s.

## Per-candidate reports

| # | Report | Lang | Standout technique |
|---|--------|------|--------------------|
| 1 | [01-mrhttp](01-mrhttp.md) | Python+C | pipelining; `cache` precomputed response; uvloop prefork |
| 2 | [02-faf](02-faf.md) | Rust | epoll thread-per-core; **CBPF CPU steering**; no-libc raw syscalls |
| 3/8 | [03-libreactor](03-libreactor.md) | C | **closest analogue**: epoll reactor, coalescing, Date cache, CBPF steering |
| 4 | [04-pico.v](04-pico.v.md) | V→C | picoev + picohttpparser (SSE4.2); taskset prefork-per-core |
| 5 | [05-uwebsockets.js](05-uwebsockets.js.md) | JS/C++ | `DeclarativeResponse` precompute; write "corking"; cluster+reuseport |
| 6 | [06-silverlining](06-silverlining.md) | Go | bypasses net/http; sync.Pool arenas; prefork+reuseport |
| 7 | [07-lithium](07-lithium.md) | C++ | compile-time monomorphization; **two-pass PGO**; fibers on epoll |
| 9 | [08-may-minihttp](08-may-minihttp.md) | Rust | stackful coroutines (`may`); coalescing; cached Date |
| 10 | [09-aspnetcore-aot](09-aspnetcore-aot.md) | C# | platform bypass of MVC; Pipelines flush-coalescing; NativeAOT |

Provenance and the captured leaderboard: [`research-sources/README.md`](../../research-sources/README.md),
[`research-sources/RANKINGS-r23-plaintext.md`](../../research-sources/RANKINGS-r23-plaintext.md).
