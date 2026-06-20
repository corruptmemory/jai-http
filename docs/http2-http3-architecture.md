# HTTP/1.1 → HTTP/2 → HTTP/3: architecture notes for jai-http

**Date:** 2026-06-20
**Context:** grew out of the TechEmpower r23 plaintext research (`docs/research/`)
and reverse-engineering the nginx clone at `../nginx`. Captures a design
discussion about pipelining, HTTP/2 multiplexing, how nginx layers newer
protocols onto an HTTP/1.1-shaped core, and what any of it would mean for
jai-http.

## TL;DR

- **HTTP/1.1 pipelining** (the thing the TFB plaintext leaders exploit) is a
  near-dead, benchmark-favored optimization. Real clients don't pipeline.
- **HTTP/2** is the *successful* "many requests per connection" design:
  multiplexed independent streams, not FIFO-ordered pipelining.
- **nginx (and us) = a virtualized HTTP/1.x request/response session behind an
  HTTP/2 mux/demux.** The newer protocols are *adapter modules* over an
  unchanged h1-shaped core. App/handler logic is protocol-agnostic.
- **Real-world value of h2/h3 is latency/UX on asset-heavy, high-RTT, lossy
  links — not throughput.** On localhost/LAN it buys ~nothing (often negative),
  which is why the benchmark leaders run h1.
- **Decision (this project): HTTP/2, HTTP/3, and TLS are out of scope** —
  edge-terminated by Cloudflare (a `cloudflared` tunnel from node-0). jai-http
  speaks plain HTTP/1.1; Cloudflare provides h2/h3, HTTPS, and DDoS protection.
  See §8.

## 1. Pipelining is a benchmark artifact

HTTP/1.1 pipelining = the *client* writes N requests back-to-back without waiting
for responses; the server's single `recv` already has all N, drains them, and
coalesces the N responses into one `writev`. **Zero added latency** (no hold
window — the requests are already there) and the requests need not be identical.
It's spec-compliant, general code; it just only pays off when traffic is
pipelined.

It almost never is:
- **Browsers**: none pipeline today. Chrome removed it (~2014), Firefox kept it
  behind a default-off pref then removed it (~2017); only old Opera/Presto shipped
  it on. Browsers used 6 parallel connections instead, then moved to HTTP/2.
- **Client libs**: **curl removed HTTP/1.1 pipelining in 7.62.0 (2018)**. The rare
  mainstream client that still does it is Node's **undici** (`pipelining: N`).
  `requests`, Go `net/http` client, .NET `HttpClient`, Apache HttpClient: no.
- **Load generators** (wrk+Lua, the TFB harness): yes — *this is the benchmark*,
  not a real client.

Our own `bench.sh` runs **non-pipelined** wrk, so our ~1.8M numbers already reflect
realistic traffic; the leaders' ~28M is a different (pipelined) workload.

## 2. HTTP/2 = multiplexing (the version that worked)

HTTP/2 puts many requests in flight on one connection as independent **streams**;
the connection carries **frames** from many streams, **interleaved** on the wire.

The make-or-break difference vs. pipelining is **ordering**:
- *Pipelining*: responses must come back in request order → one slow response
  head-of-line-blocks the rest. Fragile → died.
- *HTTP/2*: streams are independent, no ordering constraint → a slow stream doesn't
  block others. That one change is why h2 succeeded.

Also: **HPACK** header compression (stateful, shared, ordered dynamic table),
SETTINGS/flow-control/priority/RST_STREAM/GOAWAY. (Server push: effectively dead,
Chrome removed it 2022. h2 priorities: deprecated, replaced by RFC 9218.)
Caveat: h2 still rides **one TCP connection**, so a lost packet stalls *all*
streams at the transport layer — "TCP-level HOL." That residual problem is what
HTTP/3 fixes.

## 3. nginx's architecture: the "HTTP NAT map"

nginx's core *reads as* a classic HTTP/1.1 server because it **is** one — and that's
deliberate. HTTP/2 and HTTP/3 are bolted on as adapter modules so the core never
had to change. Verified in `../nginx`:

- **Core is h1-shaped, protocol-agnostic.** `ngx_connection_t` + `ngx_event_t`
  (`read->handler`/`write->handler` fn-pointers) feeding the phased request
  pipeline (rewrite → access → content → output filters), built around "one
  connection, one request at a time."
- **On ALPN=h2 the real connection is hijacked.** `ngx_http_v2_init`
  (`src/http/v2/ngx_http_v2.c:204`) swaps `rev->handler = ngx_http_v2_read_handler`
  and `c->write->handler = ngx_http_v2_write_handler` (`:301-302`). The real TCP
  connection now belongs to the frame machinery.
- **Each stream gets a *fake connection* + a *synthesized request*.**
  `ngx_http_v2_create_stream` (`:2980`) pulls a fake `ngx_connection_t` from a
  free-list (`free_fake_connections`, `:2991`), gives it its own `fc->read`/
  `fc->write` events (`:3051`); `ngx_http_v2_construct_request_line` rebuilds the
  request, tagged `NGX_HTTP_VERSION_20`. To everything downstream, a stream looks
  exactly like a normal request on a normal connection — the phases/handlers/most
  filters run unchanged.
- **Output is re-framed by a dedicated filter.** `ngx_http_v2_header_filter`
  (`ngx_http_v2_filter_module.c:107`) re-encodes headers as HPACK + HEADERS
  frames; the body filter chops the body into DATA frames, multiplexed and
  flow-controlled onto the one real connection.

**The metaphor (apt):** it's an **HTTP NAT map** — the mux/demux maps
`{connection, stream-id} ↔ virtual request`, exactly like NAT maps
`{public addr,port} ↔ {private addr,port}`. The h2 module virtualizes "request"
onto "stream" so the ~90% of the codebase downstream of the request object never
learns h2 exists.

The new code is concentrated in three places (and *is* the "big lift"): frame
demux + stream state machine (`ngx_http_v2.c`, ~140 KB), HPACK
(`ngx_http_v2_table.c`), output reframing + flow control
(`ngx_http_v2_filter_module.c`, ~48 KB).

## 4. What does HTTP/2-native application logic look like? Identical.

Because the adapter virtualizes streams into requests, **handler code is
protocol-agnostic** — there is no "HTTP/2-native" way to write app logic that
looks different from h1. You still write `(request, response) -> ...`.

**Go `net/http` confirms this exactly.** Its h2 support (originally
`golang.org/x/net/http2`, folded into the std lib for TLS servers) serves HTTP/2
**transparently through the same `http.Handler` interface** —
`ServeHTTP(w ResponseWriter, r *Request)` is unchanged; `*http.Request` exposes
`ProtoMajor` (1 or 2) but handlers almost never look at it. Same pattern as nginx:
a mux/demux front-half feeding an unchanged handler model. This validates
jai-http's design — our router → handler → helpers → Pool machinery would stay
put; h2 is purely an additive front-half.

## 5. Real-world value: how much does the complexity buy?

Honest, workload-dependent. **h2/h3 are latency/UX features, not throughput
features.**

| Scenario | h2 benefit |
|---|---|
| Many small assets (JS/CSS/img/fonts) over high-RTT internet/mobile | **Large** — one multiplexed conn vs. 6 HOL-blocked conns; the classic win |
| Header-heavy APIs (big cookies) | Moderate — HPACK |
| Fewer sockets / TLS handshakes / server memory | Moderate, real |
| Single large transfer | ~None (one stream; h1 equal) |
| **localhost / LAN, low RTT** | **~None, often *negative*** — framing+HPACK overhead with no multiplexing payoff |
| Raw req/s throughput on a fast network | Small — h2 reduces connections/latency, not throughput |
| **Lossy networks** | **Can be *worse*** — one TCP connection means one lost packet stalls all streams (TCP HOL) |

This is why the TFB plaintext leaders use **h1, not h2** (h2's overhead would *cost*
raw throughput), and why h2 buys little for **our** near-term target
(weather-station: htmx, a handful of endpoints, home LAN, low RTT — none of the h2
wins apply).

**The pragmatic deployment** most apps actually use: a reverse proxy (nginx,
Caddy, Cloudflare) **terminates h2/h3 at the edge and speaks h1 to the app** over a
low-RTT LAN hop — where h1 keep-alive is optimal. So an app server frequently
**never needs native h2/h3**: it gets the client-facing benefit for free and keeps
its hot path simple. For jai-http this is the likely answer indefinitely.

## 6. HTTP/3 / QUIC: what it adds

HTTP/3 = HTTP semantics over **QUIC**, a reliable transport on **UDP**.

- **Fixes TCP-level HOL.** QUIC implements streams *in the transport*, with
  independent delivery — a lost packet only blocks the stream(s) whose bytes it
  carried; other streams proceed. This finally delivers h2's multiplexing promise
  on lossy/mobile networks.
- **Faster setup.** QUIC merges transport + TLS 1.3 into a 1-RTT handshake (0-RTT
  on resumption).
- **Connection migration.** Connections are keyed by a **connection ID**, not the
  4-tuple, so a client can switch networks (wifi↔cellular) without dropping.
- **Mandatory, pervasive encryption** (even most transport headers) — resists
  middlebox ossification.
- **User-space transport** (UDP) → **more CPU per byte** than kernel TCP (GSO/GRO
  help but it's heavier); h3 is often more CPU-intensive server-side than h2.
- **QPACK** replaces HPACK (redesigned so header compression doesn't reintroduce
  HOL across streams).

**The lift is much bigger than h2** — you need a whole reliable-transport stack in
user space (congestion control, loss recovery, ACKs, flow control, stream mgmt)
with TLS 1.3 integral. Nobody hand-rolls it; you wrap a library (quiche, ngtcp2,
msquic, lsquic). nginx's is `../nginx/src/http/v3/` (its newest, most complex
module).

**But the application adapter is unchanged.** h3 still demuxes streams that
virtualize into the same request/response handlers — the new complexity is almost
entirely in the **transport**, not the app layer. The "HTTP NAT map" model holds,
with an extra transport layer beneath it.

**Real-world value:** incremental over h2 — mostly lossy/mobile links and
setup/migration. On a clean datacenter/LAN, h3 ≈ h2 (or slightly worse on CPU).

## 7. Implications for jai-http

- **Our design is already the right shape.** Protocol-agnostic handlers +
  per-request Pool + shared-nothing workers = exactly what makes the nginx adapter
  approach viable later. We modeled on nginx; the nginx playbook ports directly.
- **If/when HTTP/2:** an *additive front-half* (frame layer + stream state machine,
  HPACK dynamic table, output reframing + flow control) feeding our unchanged
  router/handler. Our per-request Pool becomes a **per-stream Pool** (clean fit —
  nginx even pools its fake connections). **Prerequisite: TLS + ALPN** (browsers
  do h2 only over TLS) — which means wrapping a mature TLS library, not
  hand-rolling crypto (same call as the future libcurl-based client).
- **HTTP/3:** materially bigger (a QUIC library + TLS 1.3); defer well past h2.
- **Most likely we never implement either natively** — front jai-http with a proxy
  that terminates h2/h3 and speaks h1 upstream. Native h2/h3 only earns its keep if
  jai-http itself becomes the public edge for an asset-heavy, internet-facing site.

## 8. Decision & deployment for this project (2026-06-20)

**Decision: HTTP/2, HTTP/3, and TLS are out of scope for jai-http.** The library
speaks plain HTTP/1.1 (keep-alive); everything modern-web is terminated at the
edge. This keeps the hot path simple and fast and sidesteps the QUIC / HPACK /
crypto tarpits entirely.

**End-state targets:** a personal blog and smallish demo apps — low-traffic, not
asset-farm SPAs — for which HTTP/1.1 keep-alive behind an edge is entirely
sufficient.

**Deployment topology:**

```
                       h2/h3 + TLS                 outbound-only tunnel
   browser ───────────────────────▶ Cloudflare ───────────────────────▶ node-0
                                    edge (TLS,         (no open ports,      │
                                    h2/h3, DDoS)        no static IP)        │
                                                                  cloudflared │
                                                                              ▼
                                                                  Caddy :80 (Host routing)
                                                                              │
                                                                              ▼
                                                            jai-http app — plain HTTP/1.1 on a
                                                            local port, systemd unit (like the
                                                            existing Go weather-station)
```

- **node-0** (home server, basement): HP Dev One — AMD Ryzen 7 PRO 5850U
  (8C/16T Zen 3), 32 GB, NVMe; Arch Linux + systemd + Docker; Servers VLAN 30
  (`192.168.30.204`). Already fronts Immich, the Go weather-station (`:8080`,
  systemd unit under `/opt/weather-station`), and Open Brain via **Caddy on `:80`**
  routing by Host header. jai-http apps deploy the same way: a systemd unit on a
  local port + a Caddy vhost.
- **cloudflared** runs on node-0 as an **outbound-only** tunnel to the Cloudflare
  edge — no inbound ports opened, no static IP needed (Verizon Fios is ~1 Gbps
  symmetric, but services are deliberately never exposed directly; inbound is
  blocked anyway). Public traffic arrives as `https://service.domain.com`.
- **Cloudflare** provides HTTP/2 + HTTP/3, HTTPS/TLS termination, and DDoS
  protection — the "h2/h3 sauce" — so jai-http never has to. Free tier covers it.
  (This matches the home self-hosting architecture recorded in Open Brain,
  2026-04-16: Cloudflare Tunnel chosen for zero-cost, zero-open-port public HTTPS.)

**Why this is the right call (not a cop-out):** §5 showed h2/h3 are latency/UX
features for asset-heavy, high-RTT, lossy *client-facing* links — exactly what a
CDN edge is for — while the `cloudflared → node-0 → app` hop is a low-RTT path
where **HTTP/1.1 is optimal**. The edge does what edges are good at; the app does
what it's good at. Native h2/h3 in the library would only earn its keep if jai-http
itself became the public internet edge — which this topology guarantees it never
is.

## Sources
- nginx clone: `../nginx/src/http/v2/` (cited above), `../nginx/src/http/v3/`.
- TFB plaintext research: `docs/research/` (esp. the pipelining finding).
- Go `net/http` + `golang.org/x/net/http2` (transparent h2 via `http.Handler`).
- node-0 specs + the Cloudflare-Tunnel self-hosting decision: Open Brain memory
  (2026-04-10 / 2026-04-16).
