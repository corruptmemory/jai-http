# Design: chunked request bodies and slow-client defenses

**Date:** 2026-10-03
**Status:** direction approved in chat 2026-10-03; this spec is under review. The implementation
plan follows its approval.
**Branch:** `chunked-slow-clients`, from master after PR #5 (fib-lifts) merged.
**Origin:** the two open items from PR #5's review: chunked request bodies are refused with 501
(R5), and slow readers can pin memory (D1).

## 1. Why

**Chunked bodies.** PR #5 answers any `Transfer-Encoding` with 501. That closed a desync (R5): the
server used to ignore the header and parse the chunks as further requests. But the deployment
path is Caddy, then cloudflared, then the app. Both are written in Go, and Go forwards a
request body of unknown length chunked; an HTTP/2 or HTTP/3 upload without `Content-Length` is
the common case. Those requests fail today.

**Slow clients.** The Internet is hostile, and a slow client is cheap to fabricate. In this
event-driven server a slow connection holds no thread; it sits in epoll. What it does hold is a
pool slot (with its fd), its preallocated read buffer, and any pending response tail on the heap.
What bounds each today:

| Resource                        | Bounded today by                                                         | Gap                                                     |
|---------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------|
| A request in progress           | HEADER 10 s and BODY 30 s, total deadlines from the request's first byte | none: pacing cannot stretch them                        |
| A response tail (up to 1 MB)    | WRITE: 30 s with no progress                                             | reading 1 byte every 29 s holds it forever              |
| All tails together              | nothing                                                                  | 16 workers × 1024 slots × 1 MB = 16 GB                  |
| A slot whose client never sends | IDLE, 60 s from accept                                                   | 16,384 connect-and-sit sockets a minute fill every pool |

## 2. Goals and non-goals

Goals:
- Decode chunked request bodies, strictly enough that no framing ambiguity reaches a handler.
- Bound how long a slow reader may hold a response tail (a minimum drain rate).
- Bound the memory all tails on a worker may hold together (a per-worker budget).
- Bound how long a connection that never sends may hold a slot (a first-request deadline).
- Log the failures an attacker can trigger without letting them flood the error log.

Non-goals:
- **Chunked responses.** The writer keeps sending `Content-Length`.
- **Trailers for handlers.** Trailers are validated and discarded.
- **`Expect: 100-continue`.** curl waits a second and then sends the body anyway; Caddy does not
  wait for a 100 from its upstream.
- **Bodies larger than `READ_BUFFER_SIZE`.** Streaming request bodies belong with the
  large-asset work.
- **Per-IP connection limits.** Behind Caddy every peer is 127.0.0.1; they belong at the edge.
- **Evicting tails to make room.** The budget refuses new tails instead (§4.2).
- **A separate "slow client" handler.** Moving a connection moves its slot, read buffer and tail
  with it and frees nothing. Not copying tails at all (zero-copy static bodies) is the real
  version of the idea, and it belongs with the large-asset work.

## 3. Chunked request bodies

### 3.1 Framing rules

`finish_headers` collects the coding names of every `Transfer-Encoding` field, in order: each
field is split on commas, each member is OWS-trimmed, and empty members are skipped (RFC 9110
§5.6.1). A member counts as `chunked` only when it is exactly that token, compared
case-insensitively; `chunked;x=1` is some other coding. The first matching rule decides:

| #   | Request                                                                        | Answer | Reason                                                         |
|-----|--------------------------------------------------------------------------------|--------|----------------------------------------------------------------|
| 1   | HTTP/1.0 with any `Transfer-Encoding` field                                    | 400    | RFC 9112 §6.1: the framing is faulty                           |
| 2   | `Transfer-Encoding` and `Content-Length` together                              | 400    | RFC 9112 §6.3 allows rejecting it; the classic smuggling shape |
| 3   | no codings, or the last is not `chunked` (`gzip`, `chunked, gzip`, `xchunked`) | 400    | RFC 9112 §6.3: MUST                                            |
| 4   | `chunked` anywhere before the last position (`chunked, chunked`)               | 400    | RFC 9112 §6.1: chunked is applied at most once                 |
| 5   | another coding before the final `chunked` (`gzip, chunked`)                    | 501    | RFC 9112 §6.1: a coding the server does not understand         |
| 6   | exactly `chunked`                                                              | decode |                                                                |

Rules 1 to 4 map to `Parse_Error.MALFORMED`, rule 5 to `UNSUPPORTED_FRAMING`. Every refusal
goes through the existing `refuse_and_close` path.

### 3.2 Chunk grammar

RFC 9112 §7.1, parsed strictly:

```
chunked-body    = *chunk last-chunk trailer-section CRLF
chunk           = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
chunk-size      = 1*HEXDIG
last-chunk      = 1*("0") [ chunk-ext ] CRLF
chunk-ext       = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )
chunk-ext-name  = token
chunk-ext-val   = token / quoted-string
trailer-section = *( field-line CRLF )
```

- **Chunk size.** Hex digits only: no `0x`, sign or whitespace before them. Leading zeros are
  skipped. More than 15 significant digits is `BODY_TOO_LARGE` (413) without any arithmetic:
  16^15 is below 2^63, and overflow panics the process in every build (the lesson of R2). A size
  that cannot fit in what remains of the read buffer after its line is 413 at once.
- **Line ends.** Every framing line ends in CRLF, found with `find_crlf`. The line's content
  must match the grammar, so a bare LF or CR inside a line is a 400. No line is ever accepted
  with an LF-only ending; loose chunk-line terminators are a recent smuggling class ("funky
  chunks", 2025).
- **Extensions.** BWS is SP or HTAB. Extensions are parsed against the grammar and ignored, as
  RFC 9112 §7.1.1 requires. `quoted-string` follows RFC 9110 §5.6.4: `qdtext` is HTAB, SP, 0x21,
  0x23-0x5B, 0x5D-0x7E or obs-text; `quoted-pair` is a backslash before HTAB, SP, VCHAR or
  obs-text. Anything else after the size is a 400, including trailing whitespace with no `;`
  after it (`5 \r\n`). Go tolerates that one; rejecting it is safe, since being stricter than
  the front end refuses a request but cannot desync from it.
- **Chunk data.** Exactly `chunk-size` bytes, followed by exactly CRLF; anything else is a 400.
- **Trailers.** Each line is checked with the header rules (token name, no whitespace before the
  colon, a field value without control bytes) and then discarded. Trailers never enter
  `req.headers`: merging them is how trailer smuggling works, and RFC 9110 §6.5.1 lets a
  recipient discard them.

### 3.3 Decoding in place

The decoder works inside the read buffer as bytes arrive. Two cursors move through it: the read
cursor `parse_offset` walks the raw message, and the write cursor `body_end` trails it. Chunk data
is copied down to `body_end`; framing bytes are skipped. picohttpparser's `phr_decode_chunked`
uses the same in-place approach.

Decoding only ever removes bytes, so `body_end <= parse_offset` always holds, and the copy
always moves data toward lower addresses. A forward byte copy is safe even when source and
destination overlap. The existing overlap logic in `reset_for_next_request` (memcpy when the
regions are disjoint, a forward loop otherwise) becomes a shared helper, `move_down`, used by
both.

State on the connection: `chunk_phase` (SIZE, DATA, DATA_CRLF, TRAILERS), `chunk_remaining`,
`body_start` and `body_end`, offsets into `buf`. Per call of `parse_request` in state `CHUNKED`:

- **SIZE:** find the line's CRLF, or return INCOMPLETE. Validate size and extensions. A zero
  size moves to TRAILERS; otherwise set `chunk_remaining` and move to DATA.
- **DATA:** move `min(available, chunk_remaining)` bytes down to `body_end` and advance both
  cursors. At zero remaining, move to DATA_CRLF; otherwise INCOMPLETE.
- **DATA_CRLF:** with fewer than two bytes available, INCOMPLETE; anything but CRLF is a 400;
  then back to SIZE.
- **TRAILERS:** an empty line completes the request. Otherwise validate the field line and
  continue.

On completion, `req.body` is the view `buf[body_start .. body_end)`, `req.content_length` is its
length, and `parse_offset` sits just past the final CRLF. A handler cannot tell a chunked body
from a `Content-Length` one. The `Transfer-Encoding` header stays in `req.headers`, since it is
what the client sent; no `Content-Length` header is made up.

### 3.4 Integration

- **Parse state.** `Parse_State` gains `CHUNKED`. `parse_request` enters it from HEADERS when
  `finish_headers` chose rule 6, where a `Content-Length` body enters `BODY`.
- **Pipelining.** `reset_for_next_request` already shifts the buffer from `parse_offset`. The
  dead span between `body_end` and `parse_offset` is never read, so a request pipelined behind a
  chunked body needs no new code.
- **Resets.** `get_connection` and `reset_for_next_request` clear the chunk fields with the rest
  of the parse state (the R11 lesson: every per-request field is reset in both places).
- **Size cap.** The raw message, framing included, must fit in `READ_BUFFER_SIZE`, the same rule
  as for a `Content-Length` body. With the default 4 KB buffer that is roughly 3.5 KB of body.
- **Buffer full.** `read_and_dispatch` picks the refusal by state: REQUEST_LINE 414, HEADERS 431,
  and now CHUNKED 413. (`BODY` cannot fill the buffer: `finish_headers` already rejects a
  `Content-Length` that would not fit.)
- **Timeouts.** `timeout_state` treats `CHUNKED` as `BODY`, so the 30 s total deadline from the
  request's first byte bounds a trickled chunked upload.

## 4. Slow-client defenses

### 4.1 Minimum drain rate

A new parameter, `MIN_SEND_RATE`, in bytes per second: 16384 by default; 0 means no floor.

When a tail is queued (the two call sites where a write returns PENDING: `dispatch_buffered`
and `refuse_and_close`), one helper, `start_write_clock(c, now)`, sets:
- `last_write_ms = now`, as today;
- `write_deadline_ms = drain_deadline(now, c.pending.count, WRITE_TIMEOUT_MS, MIN_SEND_RATE)`.

`drain_deadline(now, bytes, grace_ms, rate)` returns 0 (no deadline) when `rate <= 0`, and
otherwise `now + grace_ms + bytes * 1000 / rate`. It takes its parameters instead of reading the
module constants, so tests can drive any value. An `#assert` guards the multiplication against
a `MAX_PENDING_BYTES` large enough to overflow it.

In the WRITE state a connection times out when either:
- it has made no progress for `WRITE_TIMEOUT_MS` (unchanged: catches dead peers quickly), or
- `write_deadline_ms` is set and has passed (new: catches peers that make progress too slowly).

Either way the connection closes without a reply, since a response is already in flight, and a
`log` line says which limit fired. `get_connection` and `release_pending` clear
`write_deadline_ms`, so a deadline never outlives its tail.

- **One tail at a time.** Dispatch pauses while output is pending, and canned replies queue only
  behind an empty tail, so a deadline is set once and never extended.
- **The arithmetic.** With the defaults, a 1 MB tail must drain within 30 + 64 = 94 s, and a
  64 KB tail within 34 s.
- **What the floor covers.** Only the bytes this process holds. Bytes already in the kernel's
  send buffer are bounded by the kernel (`tcp_wmem`).
- **Behind Caddy.** Caddy's reverse proxy streams responses by default rather than buffering
  them, so the pace the floor measures is the end user's.

### 4.2 Per-worker pending budget

A new parameter, `MAX_PENDING_PER_WORKER`, in bytes: 67108864 (64 MB) by default, which is 1 GB
across 16 workers. Like `MAX_PENDING_BYTES` it is a literal cap: 0 means no tail may queue.

- **Accounting.** `Connection_Pool`, of which each worker owns one, gains `pending_total`. Every
  `Connection` gets a `pool` back-pointer, set in `init_pool`. A tail is charged when its memory
  is reserved and refunded in `release_pending`, the one place every tail ends: drain, close,
  slot reuse and pool destruction. Counting per worker keeps the workers shared-nothing, with no
  atomics.
- **One reservation per tail.** Both writers that queue tails, `write_response` and
  `write_or_queue`, reserve the tail's exact size once and then append into it, so charge and
  refund are both `c.pending.allocated`.
- **The check.** Before either writer queues a tail, `tail_refusal(unsent, pool_total,
  MAX_PENDING_BYTES, MAX_PENDING_PER_WORKER)` returns NONE, OVER_CONNECTION_CAP or
  OVER_WORKER_BUDGET. It is a pure function, testable with small numbers. A refusal makes the
  write an ERROR: the connection closes and the client gets a truncated response, exactly what
  the per-connection cap does today.
- **Refuse, not evict.** The drain-rate floor already forces an attacker's share of the budget
  to turn over within about 94 s, so evicting the worst tail would add complexity for little.
- **Tests.** `standalone_connection` in the tests gets a real one-slot pool, so production code
  never has to handle a connection without a pool.

### 4.3 First-request deadline

`accept_connections` sets `request_start_ms = now`. A new timeout state, `NEW`, covers a
connection that was accepted and has not sent a byte (`bytes_used == 0` with `request_start_ms`
set; no other path produces that combination). Its limit is `HEADER_TIMEOUT_MS`, measured from
accept.

- **Silent close.** A `NEW` timeout closes without a 408. The client asked nothing, and a 408
  racing its first request would be read as the answer to it. nginx does the same:
  `client_header_timeout` runs from accept and a silent connection is closed without a response.
- **Once bytes arrive,** the first request's HEADER deadline keeps counting from accept, as in
  nginx, because the read path only sets `request_start_ms` when it is zero.
- **Between requests,** a kept-alive connection is IDLE (60 s), unchanged.

### 4.4 Logging

- **Per-connection closes** (drain rate, stalled write, `NEW`, IDLE, LINGER) are the client's
  doing and go to `log` (info, quietable), one line per close. The HEADER/BODY timeout, which
  logs twice today (the sweep and `refuse_and_close`), logs once.
- **Tail refusals**, over either cap, are a failure to serve. Each pool counts them by reason
  (`refused_over_connection`, `refused_over_budget`). `worker_sweep` reports them with one
  `log_error` line per worker per second when either count is nonzero, then resets them. An
  attacker who triggers refusals on every request gets one error line a second per worker, not
  one per request.
- **The sweep always runs.** `worker_run` drops the `TIMEOUTS_ENABLED` gate on its one-second
  `epoll_wait` timeout, so a refusal count is never stranded. A once-a-second wakeup per worker
  costs nothing measurable.

## 5. Parameters

New, program-wide (group 2) like every `http_server` parameter:

| Parameter                |  Default | Meaning                                                                              |
|--------------------------|---------:|--------------------------------------------------------------------------------------|
| `MIN_SEND_RATE`          |    16384 | bytes/s a queued response must average after a `WRITE_TIMEOUT_MS` grace; 0: no floor |
| `MAX_PENDING_PER_WORKER` | 67108864 | bytes all of a worker's queued tails may hold together; 0: no tail may queue         |

Changed meanings:
- `WRITE_TIMEOUT_MS` is also the grace period before the drain-rate floor bites.
- `HEADER_TIMEOUT_MS` also bounds how long a new connection may wait before sending its first
  byte.

## 6. Failure policy

| Condition                                                   | Action                                                                                          |
|-------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| chunked framing or grammar violation (§3.1 rules 1-4, §3.2) | 400, lingering close, `log` (the existing refusal path)                                         |
| a coding other than `chunked` before the final `chunked`    | 501, lingering close, `log`                                                                     |
| chunked message larger than the read buffer                 | 413, lingering close, `log`                                                                     |
| tail drains slower than `MIN_SEND_RATE` (after the grace)   | close, `log`                                                                                    |
| no write progress for `WRITE_TIMEOUT_MS`                    | close, `log` (unchanged)                                                                        |
| new connection silent for `HEADER_TIMEOUT_MS`               | close without a reply, `log`                                                                    |
| tail over `MAX_PENDING_BYTES` or the worker budget          | write ERROR, close (response truncated); counted, one `log_error` summary per worker per second |

## 7. Data structures

```jai
// http.jai
Parse_State  :: enum u8 #specified { ...; CHUNKED :: 5; }
Chunk_Phase  :: enum u8 #specified { SIZE :: 0; DATA :: 1; DATA_CRLF :: 2; TRAILERS :: 3; }
Tail_Refusal :: enum u8 #specified { NONE :: 0; OVER_CONNECTION_CAP :: 1; OVER_WORKER_BUDGET :: 2; }

// connection.jai: Connection
pool:              *Connection_Pool;   // the owning pool (one per worker); set in init_pool
chunk_phase:       Chunk_Phase;
chunk_remaining:   s64;                // bytes of the current chunk not yet arrived
body_start:        s64;                // decoded chunked body: buf[body_start .. body_end)
body_end:          s64;
write_deadline_ms: s64;                // a queued tail must have drained by then; 0: no deadline

// connection.jai: Connection_Pool
pending_total:           s64;          // bytes reserved by every queued tail in this pool
refused_over_connection: s64;          // tail refusals since the last sweep, by reason
refused_over_budget:     s64;

// server.jai
Timeout_State :: enum u8 #specified { ...; NEW :: 6; }   // accepted, no byte received yet
```

## 8. Testing

The existing sequential style, in `modules/http_server/tests/test.jai`. Parser tests use a
standalone connection; server tests use the fake worker and socketpairs, as PR #5's do.

**Chunked, accepted.** A table of good messages: one chunk; several chunks; leading zeros;
upper- and lower-case hex; extensions, including a quoted string with an escaped quote; trailers;
an empty body (`0\r\n\r\n`). Each is fed whole **and one byte at a time**, which proves the
decoder resumes correctly at every split point. `req.body` and `req.content_length` must be
exact, and no trailer may appear in `req.headers`.

**Chunked, refused.** A table of framing cases with the status each expects: TE with CL; TE on
HTTP/1.0; `gzip`; `chunked, gzip`; `xchunked`; `chunked, chunked`; an empty TE value;
`chunked;x=1` (all 400); `gzip, chunked` (501). A table of grammar cases, all 400:
- `0x5`, `+5`, `-5`, ` 5`, `5 `;
- a bare LF after the size, an LF-only line after the data;
- data longer than its size, a missing CRLF after the data;
- an invalid extension byte, an unterminated quoted string;
- a trailer name with a space, a trailer value with a control byte, an obs-fold trailer.

**Chunked, limits.** A declared size larger than the buffer is 413; many small chunks that fill
the buffer are 413 through the fake worker. A 20-hex-digit size is 413 without a panic, run in a
forked child the way the R2 test is. The R5 test changes: a chunked request is now decoded and
its handler sees the body.

**Chunked, server.** A chunked POST pipelined with a GET in one write: both are served, in
order, and the GET arrives intact. A trickled chunked upload is classified BODY and gets 408 from
the sweep (synthetic timestamps, as the existing timeout tests use).

**Drain rate.** `drain_deadline` over a table, including rate 0. `is_timed_out` on a tail that
keeps making progress but passes its deadline times out (rate, not stall); a tail that drains
before its deadline does not; a tail with no progress times out as before.

**Budget.**
- `tail_refusal` over a table.
- The accounting invariant over a socketpair: queuing a tail charges `pending_total` exactly;
  draining it, closing the connection and reusing the slot each refund it to zero; two tails sum.
  A leak here would refuse everything eventually, a slow-motion outage, so this is the test that
  matters most.
- A refusal: with `pending_total` set just under the budget, `write_response` returns ERROR and
  the budget counter increments.

**First request.** A connection attached to the fake worker that sends nothing is `NEW`, times
out after `HEADER_TIMEOUT_MS`, and its peer reads EOF with zero bytes (no 408).

**Logging.** With an error recorder installed, two refusals and then `worker_sweep` log exactly
one error; a second sweep logs none.

**Verification after the build:**
- all suites green in debug and release, and every example builds;
- the standard wrk grid against `hello_world`. No change is expected: the hot path gains one
  branch in `finish_headers`.
- real-TCP checks:
  - `curl -H "Transfer-Encoding: chunked" --data-binary @file`: the body arrives intact;
  - a download through a reader rate-limited below the floor is cut at its deadline, and one
    above the floor completes;
  - `nc` connected and silent is closed after 10 s.

## 9. Files

| File                                 | Change                                                                                                                                                       |
|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `modules/http_server/module.jai`     | two new parameters; the overflow `#assert`                                                                                                                   |
| `modules/http_server/http.jai`       | `CHUNKED` state, `Chunk_Phase`, the TE rules in `finish_headers`, the chunked decoder, `move_down`, `Tail_Refusal`, `tail_refusal`, one reservation per tail |
| `modules/http_server/connection.jai` | the new fields, the `pool` back-pointer, charge and refund in `release_pending`                                                                              |
| `modules/http_server/server.jai`     | `start_write_clock`, `drain_deadline`, `NEW`, the CHUNKED 413, the refusal summary in `worker_sweep`, the unconditional sweep, one log line per timeout      |
| `modules/http_server/tests/test.jai` | the tests above; `standalone_connection` with a pool; R5 updated                                                                                             |
| `README.md`, `CLAUDE.md`             | parameters, status, the review's open items closed                                                                                                           |

## 10. Decisions for review

1. **Aggregating the per-connection cap's error.** Today a tail over `MAX_PENDING_BYTES` logs a
   `log_error` at once. Under §4.4 it joins the once-a-second summary. Recommended, because an
   attacker can trigger it on every request; the cost is that the line arrives up to a second
   late and without the fd.
2. **A new connection's silence closes without a 408** (§4.3), as nginx does.
3. **`5 \r\n` is a 400** (§3.2). The RFC grammar forbids it; Go tolerates it.
4. **The sweep runs unconditionally** (§4.4), even in a program that disables every timeout.
