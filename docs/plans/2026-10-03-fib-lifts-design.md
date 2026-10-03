# Design: lifting fib's correctness techniques into jai-http

**Date:** 2026-10-03
**Status:** approved (design reviewed in chat 2026-10-03); implementation plan in
`2026-10-03-fib-lifts-implementation.md`
**Source reviewed:** `github.com/lesismal/fib` at commit `0034f60` (2026-10-03), a Go event-driven
networking library. Only its Linux epoll engine, HTTP/1 parser and writer, router, and buffer pool
overlap with this project; HTTP/2, HTTP/3, TLS, WebSocket, Windows and kqueue were out of scope.

## 1. Why

Reading fib against `modules/http_server` exposed two latent bugs and several missing HTTP
semantics in jai-http. None show up in the loopback benchmarks. All of them will show up at the
next milestone, serving the weather station's static assets to real clients.

1. **Partial writes are silently dropped.** `write_response` discards writev's return value, and
   `send_all` treats EAGAIN as success and exits. On a non-blocking socket whose send buffer is
   full, response bytes vanish and the next response is appended to a torn stream. Nothing logs
   it. A 300 KB JS bundle to a client over the tunnel will hit this on the first request.
2. **A request that arrives with the peer's FIN is never answered.** `handle_client` acts on
   RDHUP/HUP before IN. Under edge triggering those bits arrive in one event, so a client that
   sends a request and half-closes gets closed without a response.
3. **No timeouts.** An idle keep-alive or a half-sent header holds one of 1024 per-worker pool
   slots forever.
4. **HTTP semantics gaps.** HEAD on a GET route is a 405; a registered HEAD handler's body is
   sent; 405 has no `Allow`; 204/304 carry `Content-Length` and `Content-Type`; parse failures
   close with no status.

fib's throughput tricks (pipelined response coalescing, loop/worker split, GC-shaped buffer pools,
raw-syscall shims) were reviewed and deliberately **not** lifted. Coalescing is the lever this
project declined on 2026-06-22; the rest solve Go-runtime problems jai-http does not have.

## 2. Goals and non-goals

**Goals**

- Every byte of every response reaches the kernel or the connection is closed with a logged
  reason. No silent truncation.
- Requests are answered before hangups are honored.
- Idle, slow-header, slow-body and stalled-write connections are reaped on a configurable clock.
- HEAD, 405 `Allow`, bodiless statuses and parse-failure replies follow RFC 9110/9112.
- The `Handler` contract (`#type (request: *Request, response: *Response)`) and the `Response`
  struct are unchanged. Existing handlers, examples and the router API keep compiling as they are.
- No throughput regression on the standard wrk grid (CLAUDE.md "Benchmarking" rule).

**Non-goals**

- Pipelined response coalescing, corking, or any TechEmpower-style lever (declined 2026-06-22).
- Streaming request bodies, sendfile, a server-wide pending-bytes budget.
- The static-file handler itself. It gets its own design once this lands; this design is its
  prerequisite.

## 3. Send path

**Registration.** A connection is registered once with `EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP`.
`epoll_ctl MOD` is never called. Because the interest is edge-triggered, an always-armed OUT fires
only on the full-to-writable transition, so it costs nothing while the socket has room. An OUT
event on a connection with nothing queued is ignored. That is the common case: it fires once on
registration and once after every drain.

**Writer outcome.** `write_response(c, req, resp, date)` returns one of:

| Result    | Meaning                                                                 |
|-----------|-------------------------------------------------------------------------|
| `SENT`    | every byte reached the kernel                                           |
| `PENDING` | an unsent tail is queued on the connection; wait for EPOLLOUT           |
| `ERROR`   | the peer is gone, or the tail exceeded the cap; the caller closes       |

**Fast path.** One writev of `[header, body]`, no copy, exactly as today. The header is built
from `context.allocator`, which is the per-request Pool during dispatch.

**Slow path.** A short write (or EAGAIN) means the socket is full. The unsent tail of header and
body is copied into `Connection.pending`, a `[..] u8` whose **allocator is pinned to the heap in
`init_pool`**. It must never use the request Pool or temporary storage: both are reset underneath
a stalled response. The copy happens inside `write_response`, before the worker resets the Pool.
`Connection.pending_offset` tracks how much of the tail the kernel has since taken.

**Cap.** A new group-1 module parameter `MAX_PENDING_BYTES` (default `1048576`, 1 MB) bounds the
tail. A tail that would exceed it is an `ERROR` and the connection closes; the reason is logged at
info. Worst case memory is pool size times the cap per worker, which is unrealistic in practice
since only connections to slow readers hold a tail. The buffer is freed (`array_free`) when it
drains and when the connection is freed, so idle connections hold nothing.

**Backpressure.** While `pending.count > 0` the worker keeps **reading** the socket into the fixed
read buffer but does **not parse or dispatch**. If the read buffer fills while output is pending,
`read_stalled` is set and reading stops; the kernel keeps the rest. On OUT the worker flushes;
once drained it parses what the read buffer already holds, then, if `read_stalled` was set,
resumes reading until EAGAIN. Edge triggering never re-signals bytes already in the socket, which
is why the stalled flag is required.

**Close after send.** A non-keep-alive response that goes `PENDING` sets `close_after_send`
instead of closing. The connection closes when the tail drains.

**Flush.** `flush_pending(c)` writes from `pending[pending_offset..]` until EAGAIN (`PENDING`),
completion (`SENT`, buffer freed) or a terminal error (`ERROR`).

## 4. Event ordering

Per event, `handle_client` processes in this order:

1. **OUT with pending output:** flush. On `SENT`, close if `close_after_send`; otherwise dispatch
   buffered requests and resume a stalled read.
2. **IN:** read until EAGAIN, dispatching complete requests unless output is pending.
3. **ERR or HUP:** close now.
4. **RDHUP:** the peer half-closed and can still read. If output is pending, set
   `close_after_send`; otherwise close.

A read returning 0 (EOF) is handled like RDHUP after serving whatever is complete.

## 5. Timeouts

Four group-1 module parameters in milliseconds; `0` disables each:

| Parameter           | Default | Bounds                                                     | Measured from          |
|---------------------|--------:|------------------------------------------------------------|------------------------|
| `IDLE_TIMEOUT_MS`   |   60000 | a kept-alive connection between requests                   | `last_activity_ms`     |
| `HEADER_TIMEOUT_MS` |   10000 | a request whose headers are incomplete                     | `request_start_ms`     |
| `BODY_TIMEOUT_MS`   |   30000 | a request whose body is incomplete                         | `request_start_ms`     |
| `WRITE_TIMEOUT_MS`  |   30000 | a pending response making no progress toward the peer      | `last_activity_ms`     |

`WRITE_TIMEOUT_MS` is one more than the three approved in chat; naming it beats overloading idle.

Each connection carries `last_activity_ms` (updated on accept and on every successful read or
write progress) and `request_start_ms` (set when the first byte of a request lands, cleared when
the request has fully arrived). Both come from `seconds_since_init()` scaled to milliseconds.

The state decides which timeout applies, in this precedence: `WRITE` when output is pending;
`IDLE` when the read buffer is empty; `BODY` when `parse_state == .BODY`; otherwise `HEADER`.
**A request that has fully arrived has no deadline**: the handler runs synchronously and cannot
be interrupted, and `request_start_ms` is cleared before dispatch.

When any timeout is enabled (a compile-time constant from the parameters), `epoll_wait` uses a
one-second timeout and the worker sweeps its pool once per second. The sweep is a linear pass
over the pool array, skipping free slots and the listen sentinel. A `HEADER` or `BODY` timeout
sends a canned `408` before closing. `IDLE` and `WRITE` timeouts close silently. Every timeout
close is logged at info with the fd and the state.

## 6. HTTP semantics

- **HEAD.** `find_endpoint` in the trie falls back to the `GET` endpoint when the method is `HEAD`
  and no `HEAD` endpoint exists. An explicit `HEAD` route still wins. The handler runs so
  `Content-Length` is correct; the writer sends no body for HEAD.
- **405.** `tree_match` returns the `Allow` value for the leaf it reached, built from that node's
  endpoints, listing `HEAD` whenever `GET` is present. `dispatch` sets it as a response header.
- **Bodiless statuses.** For 1xx, 204 and 304 the writer emits no `Content-Length`, no
  `Content-Type` and no body, whatever the handler put in `Response.body`.
- **Parse failures.** A canned static reply with `Connection: close` precedes the close: `400`
  malformed, `413` when `Content-Length` exceeds the read buffer, `431` when the header block
  alone fills the read buffer. Canned replies are written with a single attempt and are never
  queued. `parse_request` records the cause in `Connection.parse_error`.
- **Connection header.** Omitted on HTTP/1.1 keep-alive, which is the default. Sent as `close`
  when closing and as `keep-alive` only for HTTP/1.0 keep-alive.
- **Date.** Each worker caches a formatted `Date` string and refreshes it once per epoll batch
  when the wall-clock second has changed. The writer takes the string as a parameter; an empty
  string omits the header, which is what the tests pass.

## 7. Small items

- `reset_for_next_request` uses `memcpy` when the leftover region does not overlap its
  destination and keeps the forward byte loop when it does. Jai's `memcpy` is an LLVM intrinsic
  with undefined behavior on overlap, and there is no `memmove` binding in Basic.

## 8. Failure policy (no silent failures)

| Condition                                   | Action                                   |
|---------------------------------------------|------------------------------------------|
| `EPIPE` / `ECONNRESET` on write, `ECONNRESET` on read | the client left; close, no log |
| any other write/read/epoll errno            | `log_error` with fd and errno, close     |
| pending cap exceeded                        | `log` (info) with fd and sizes, close    |
| timeout                                     | `log` (info) with fd and state, close    |
| parse failure                               | `log` (info) with fd and status, canned reply, close |

## 9. Data structures

```jai
// connection.jai additions
pending:          [..] u8;   // unsent response tail; allocator pinned to the heap in init_pool
pending_offset:   s64;       // bytes of `pending` the kernel has taken
close_after_send: bool;
read_stalled:     bool;
last_activity_ms: s64;
request_start_ms: s64;
parse_error:      Parse_Error;   // NONE | MALFORMED | BODY_TOO_LARGE, valid after parse_request returns .ERROR

// http.jai additions
Write_Result :: enum u8 #specified { SENT :: 0; PENDING :: 1; ERROR :: 2; }
Parse_Error  :: enum u8 #specified { NONE :: 0; MALFORMED :: 1; BODY_TOO_LARGE :: 2; }

// server.jai additions (Worker)
date:        string;      // view into date_buf, refreshed per batch
date_buf:    [29] u8;
date_second: s64;
```

## 10. Testing

Unit tests follow the existing sequential style in `modules/http_server/tests/test.jai` and
`modules/http_router/tests/test.jai`. Socket-level tests use an `AF_UNIX` `socketpair` with a
small `SO_SNDBUF` on the server side and a peer that does not read, which forces the pending
path deterministically without sleeping.

- Writer: full send; partial send goes pending, draining the peer and flushing completes with the
  exact bytes; a 2 MB body against the 1 MB cap is an error with nothing queued; peer closed
  mid-flush is an error; HEAD sends no body but the right `Content-Length`; 204 has neither;
  `Connection` header rules; `Date` present and absent.
- Event handling: `handle_client` called directly on a connection whose peer sent a request and
  half-closed, with `IN | RDHUP` set together, must produce the response; two pipelined requests
  with a stalled first response must dispatch the second only after the drain; oversized header
  yields `431`; oversized `Content-Length` yields `413`; malformed yields `400`.
- Timeouts: state classification and `is_timed_out` with synthetic timestamps; the sweep closes
  an idle connection and sends `408` for a stalled header.
- Router: HEAD falls back to GET, explicit HEAD wins, `Allow` lists the right methods.

Verification after the build: all suites green, every example builds, curl checks for HEAD,
HTTP/1.0 and a rate-limited large download, and the standard wrk grid against `hello_world`
compared to a baseline taken before the first change.

## 11. Files

| File                                  | Change                                                        |
|---------------------------------------|---------------------------------------------------------------|
| `modules/http_server/module.jai`      | five new group-1 parameters                                   |
| `modules/http_server/connection.jai`  | new fields, allocator pinning, `release_pending`, resets      |
| `modules/http_server/http.jai`        | `Write_Result`, `Parse_Error`, writer rewrite, `flush_pending`, canned replies, `format_http_date`, `status_has_body`, shift copy |
| `modules/http_server/server.jai`      | EPOLLOUT registration, `handle_client` split, timeouts, date cache, exported seams |
| `modules/http_server/tests/test.jai`  | socketpair helpers and the tests above                        |
| `modules/http_router/trie.jai`        | HEAD fallback, `Allow` builder, third return from `tree_match` |
| `modules/http_router/router.jai`      | set `Allow` on 405                                            |
| `modules/http_router/tests/test.jai`  | HEAD and `Allow` tests                                        |
| `CLAUDE.md`                           | status, parameters, patterns                                  |
