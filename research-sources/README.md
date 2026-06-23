# research-sources — TechEmpower r23 plaintext top-10 (vendored snapshot)

Vendored source snapshots of the top performers in the TechEmpower Framework
Benchmarks **Round 23 — Plaintext** test, captured for performance research.
Goal: catalog the techniques these servers use to reach ~28M req/s (~18× nginx
on the same hardware) so we can decide which apply to jai-http.

## Provenance

- **Leaderboard:** https://www.techempower.com/benchmarks/#section=data-r23&test=plaintext
  — captured 2026-06-20 via the live site (see `RANKINGS-r23-plaintext.md`).
- **Source:** [TechEmpower/FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks)
  @ commit `57d92fbec6f8fd7431bc77326dd0484e60c96e20`, sparse-checkout of each
  framework's `frameworks/<Lang>/<name>/` directory, copied verbatim.
- **License:** the TFB harness is BSD-3-Clause; each vendored framework entry
  carries its own upstream license. These are vendored **for study only**, not
  redistribution or use as a product.

## Rank → directory map

The top 10 rows are 9 distinct projects — **libreactor holds two slots** (#3 a
platform-classified config, #8 a micro-framework config). Directories are
numbered by each project's *best* rank.

| Dir | Project | Best rank | Req/s | Lang | Note |
|-----|---------|-----------|------:|------|------|
| `01-mrhttp/`         | mrhttp         | 1  | 28,384,305 | Python | C core via Cython-like ext |
| `02-faf/`            | faf            | 2  | 28,034,705 | Rust   | io_uring, thread-per-core |
| `03-libreactor/`     | libreactor     | 3 & 8 | 28,025,992 | C   | self-contained epoll reactor |
| `04-pico.v/`         | pico.v         | 4  | 28,025,837 | V      | picoev/picohttpparser |
| `05-uwebsockets.js/` | uWebSockets.js | 5  | 27,991,649 | JS/Node | binding to uWebSockets (C++) |
| `06-silverlining/`   | silverlining   | 6  | 27,962,675 | Go     | prefork, custom parser |
| `07-lithium/`        | lithium        | 7  | 27,953,333 | C++    | metaprogrammed async server |
| `08-may-minihttp/`   | may-minihttp   | 9  | 27,906,423 | Rust   | `may` stackful coroutines |
| `09-aspnetcore-aot/` | aspnetcore-aot | 10 | 27,770,995 | C#     | Kestrel platform + NativeAOT |

## Important: TFB entry vs. engine

For several of these, the vendored TFB directory is the *integration* (handler +
Dockerfile + build flags), while the perf-critical engine lives upstream
(uWebSockets.js → uWebSockets C++; may-minihttp → `may` runtime; aspnetcore-aot →
Kestrel; mrhttp → its C core; lithium → the Lithium library). The per-candidate
reports in `docs/research/` cover the full technique stack, citing upstream where
the vendored snapshot only shows the binding.
