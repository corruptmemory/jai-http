# TechEmpower Round 23 — Plaintext leaderboard (captured 2026-06-20)

Source: https://www.techempower.com/benchmarks/#section=data-r23&test=plaintext
Captured live via Brave/marksnip. Absolute req/s depend on TechEmpower's
(unknown-to-us) hardware/network; **relative** standing is the useful signal.
`Class`: Mcr = Micro, Plt = Platform, Ful = Fullstack.

| Rank | Framework | Req/s | % of best | Lang | Class |
|-----:|-----------|------:|----------:|------|-------|
| 1  | mrhttp                  | 28,384,305 | 100.0% | Python | Mcr |
| 2  | faf                     | 28,034,705 | 98.8%  | Rust   | Plt |
| 3  | libreactor              | 28,025,992 | 98.7%  | C      | Plt |
| 4  | pico.v                  | 28,025,837 | 98.7%  | V      | Mcr |
| 5  | uwebsockets.js          | 27,991,649 | 98.6%  | JS     | Plt |
| 6  | silverlining            | 27,962,675 | 98.5%  | Go     | Plt |
| 7  | lithium                 | 27,953,333 | 98.5%  | C++    | Mcr |
| 8  | libreactor              | 27,943,940 | 98.4%  | C      | Mcr |
| 9  | may-minihttp            | 27,906,423 | 98.3%  | Rust   | Mcr |
| 10 | aspnetcore-aot          | 27,770,995 | 97.8%  | C#     | Plt |
| 11 | firenio-http-lite       | 27,755,180 | 97.8%  | Java   | Plt |
| 12 | aspnetcore              | 27,530,836 | 97.0%  | C#     | Plt |
| 13 | ultimate-express        | 27,324,164 | 96.3%  | JS     | Mcr |
| 14 | elysia                  | 26,060,081 | 91.8%  | TS/Bun | Mcr |
| 16 | just-js                 | 25,739,560 | 90.7%  | JS     | Plt |
| 17 | ntex [raw]              | 24,925,515 | 87.8%  | Rust   | Plt |
| 18 | gnet                    | 24,924,048 | 87.8%  | Go     | Plt |
| 20 | libsniper               | 24,120,587 | 85.0%  | C++    | Plt |
| 28 | xitca-web               | 18,436,533 | 65.0%  | Rust   | Mcr |
| 30 | httpbeast               | 17,955,351 | 63.3%  | Nim    | Plt |

(Rows 1–30 shown for context; the research set is the **top 10**.) For reference,
the user observed **nginx at ~124th place** on this chart — so "beats nginx" still
leaves a ~18× headroom gap to the leaders. Their numbers reflect *pipelined*
plaintext (wrk with 16 pipelined requests/connection), which rewards batching and
amortized syscalls far more than our current single-request-per-read loop.
