# fib lifts: send queue, event ordering, timeouts, HTTP semantics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make jai-http's write path correct under a full socket buffer, answer requests that arrive with the peer's FIN, reap idle and stalled connections, and bring HEAD / 405 / bodiless statuses / parse-failure replies in line with RFC 9110, without changing the `Handler` contract.

**Architecture:** Connections register once with a permanent edge-triggered `EPOLLOUT`. The writer reports `SENT | PENDING | ERROR`; a short write copies the unsent tail into a heap-pinned per-connection buffer that `EPOLLOUT` drains, and dispatch pauses while a tail is queued. `handle_client` is split into flush → read-and-dispatch → hangup. A once-per-second sweep applies four timeouts classified by what the connection is waiting for. All socket writes use `MSG_NOSIGNAL`, which also closes a latent SIGPIPE hazard.

**Tech Stack:** Jai beta 0.2.030 at `~/jai/jai/`; standard modules Basic, Pool, POSIX, Linux, Socket, Thread only. Build and test only through `first.jai` (see Global Constraints).

**Spec:** `docs/plans/2026-10-03-fib-lifts-design.md` (read it first; this plan argues from it).

## Global Constraints

- **Load the `jai-language` skill before writing or editing any Jai** (project CLAUDE.md, mandatory, applies to every task and every subagent).
- Build and test only via the metaprogram: `~/jai/jai/bin/jai-linux first.jai - run-tests` (all suites), `~/jai/jai/bin/jai-linux first.jai - <example>` (one example), `~/jai/jai/bin/jai-linux first.jai -` (all examples). Never call the compiler on a module file directly.
- `Handler :: #type (request: *Request, response: *Response)` and the `Response` struct are unchanged. `examples/*.jai` must keep compiling without edits (Task 8 adds one example; it edits none).
- Module parameters are not visible to importers. Tests assert the documented defaults as literals: `MAX_PENDING_BYTES = 1048576`, `IDLE_TIMEOUT_MS = 60000`, `HEADER_TIMEOUT_MS = 10000`, `BODY_TIMEOUT_MS = 30000`, `WRITE_TIMEOUT_MS = 30000`, `READ_BUFFER_SIZE = 4096`.
- `Connection.pending` is allocated only from the heap allocator pinned in `init_pool`. Never from the request Pool, never from temporary storage.
- Every socket write uses `send`/`sendmsg` with `.NOSIGNAL`. No `write`/`writev` on a socket in module code.
- Jai precedence trap: `&` binds looser than `==`. Every bit test is written `(events & FLAG) != 0`.
- Failure policy (spec §8): `EPIPE`/`ECONNRESET` close silently; any other errno goes through `Basic.log_error`; cap, timeout and refusal closes go through `Basic.log` with the fd and the reason.
- Test style: sequential `test_*` procs printing `  PASS: name`, registered in `main`, as the existing suites do. No sleeping in tests; the socket tests force conditions with `SO_SNDBUF`.
- Per CLAUDE.md "Benchmarking": the standard wrk grid must be re-run at the end and compared to the Task 1 baseline. A regression blocks the merge.
- Branch first: all work on `fib-lifts`, never directly on `master`.

## Review Focus

Inputs the spec implies but that are easy to leave untested. Each line is pinned to a test in the task that owns the code.

1. **Two requests in one segment, first response stalls.** The second must be served after the drain, in order, and never twice. → Task 4 `test_handle_client_pending_blocks_dispatch`.
2. **Peer closes while a tail is pending.** The flush must report `ERROR`, the slot must free, and nothing may log as an error. → Task 3 `test_flush_pending_peer_gone`.
3. **Read buffer fills exactly while output is pending.** Must set `read_stalled`, not refuse with 431. → Task 4 `test_handle_client_full_buffer_while_pending_stalls_read`.
4. **Explicit HEAD route beside a GET route.** The HEAD route must win over the GET fallback. → Task 5 `test_explicit_head_route_wins`.
5. **A stalled write that then drains.** `WRITE` must apply while pending; `IDLE` from the drain time afterwards, not from the request. → Task 6 `test_is_timed_out_write_then_idle`.

---

## File Structure

| File                                 | Responsibility after this plan                                                                              |
|--------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `modules/http_server/module.jai`     | module parameters (five new)                                                                                |
| `modules/http_server/connection.jai` | `Connection` state, pool, `release_pending`, `append_bytes`                                                 |
| `modules/http_server/http.jai`       | types, parser, writer (`write_response`, `flush_pending`), canned replies, `format_http_date`, buffer shift |
| `modules/http_server/server.jai`     | worker loop, accept, `handle_client` and its helpers, timeouts, date cache                                  |
| `modules/http_server/tests/test.jai` | server suite + socket helpers                                                                               |
| `modules/http_router/trie.jai`       | HEAD fallback, `Allow` builder, `tree_match` third return                                                   |
| `modules/http_router/router.jai`     | `Allow` on 405                                                                                              |
| `modules/http_router/tests/test.jai` | router suite                                                                                                |
| `examples/large_body.jai`            | new: 1 MB body for the manual slow-client check                                                             |
| `CLAUDE.md`                          | status, parameters, patterns                                                                                |

---

### Task 1: Baseline and branch

**Files:** none modified.

- [x] **Step 1: Branch**

The `fib-lifts` branch already exists on the remote with the design, this plan and the CLAUDE.md note committed (2026-10-03). Check it out rather than creating it:

```bash
cd ~/projects/jai-http && git fetch origin && git checkout fib-lifts && git pull --ff-only
```

- [x] **Step 2: Confirm everything is green before touching anything**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: every suite prints `All tests passed.` (50 http_server + 31 router + 19 datetime + 15 channel + 15 CSV + JSON harness).

Run: `~/jai/jai/bin/jai-linux first.jai -`
Expected: `build_debug/{hello_world,hello_world_raw,app_state,multipath}` all build.

- [x] **Step 3: Record the wrk baseline (release build)**

```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
./build_release/hello_world &
sleep 1
for cfg in "1 10" "4 100" "8 500" "16 1000" "32 2000"; do set -- $cfg; wrk -t$1 -c$2 -d10s http://localhost:9090/ | grep -E 'Requests/sec|Socket errors|Non-2xx'; done
kill %1
```

Paste the five `Requests/sec` lines into the **Appendix: wrk baseline** section at the bottom of this file with the date. Task 8 compares against them.

- [x] **Step 4: Commit the baseline numbers**

```bash
git add docs/plans/2026-10-03-fib-lifts-implementation.md
git commit -m "docs(fib-lifts): record wrk baseline before any change"
```

---

### Task 2: Module parameters and Connection state

**Files:**
- Modify: `modules/http_server/module.jai` (the `#module_parameters` block, lines 2-9)
- Modify: `modules/http_server/connection.jai` (whole file)
- Modify: `modules/http_server/http.jai` (add `Parse_Error` next to `Parse_State`, ~line 29)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Produces: parameters `MAX_PENDING_BYTES: s64`, `IDLE_TIMEOUT_MS: s64`, `HEADER_TIMEOUT_MS: s64`, `BODY_TIMEOUT_MS: s64`, `WRITE_TIMEOUT_MS: s64`; `Parse_Error` enum; `Connection` fields `pending`, `pending_offset`, `close_after_send`, `read_stalled`, `last_activity_ms`, `request_start_ms`, `parse_error`; procs `release_pending :: (c: *Connection)` and `append_bytes :: (arr: *[..] u8, data: *u8, count: s64)`.

- [ ] **Step 1: Write the failing test**

Append to the test file, before `main`:

```jai
// -- Send-path state (Task 2) --

test_pending_defaults_and_release :: () {
    pool: Connection_Pool;
    init_pool(*pool, 2);
    defer destroy_pool(*pool);

    c := get_connection(*pool);
    assert(c.pending.count == 0 && c.pending_offset == 0, "fresh connection has no pending output");
    assert(c.pending.allocator.proc != null, "pending allocator must be pinned at init_pool");
    assert(!c.close_after_send && !c.read_stalled, "send-path flags start clear");
    assert(c.last_activity_ms == 0 && c.request_start_ms == 0, "timestamps start at zero");
    assert(c.parse_error == .NONE, "parse_error starts NONE");

    bytes := "hello";
    append_bytes(*c.pending, bytes.data, bytes.count);
    append_bytes(*c.pending, bytes.data, 0);   // zero-length append is a no-op
    assert(c.pending.count == 5, "append_bytes should grow pending to 5, got %", c.pending.count);
    assert(c.pending[0] == #char "h" && c.pending[4] == #char "o", "bytes copied in order");

    free_connection(*pool, c);
    assert(c.pending.count == 0 && c.pending.data == null, "free_connection must release pending");
    assert(c.pending.allocator.proc != null, "release keeps the pinned allocator");

    print("  PASS: test_pending_defaults_and_release\n");
}
```

Register in `main` after the "Connection pool" group:

```jai
    print("\nSend-path state:\n");
    test_pending_defaults_and_release();
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile error in the tests workspace, `Undeclared identifier 'append_bytes'` (or `pending`).

- [ ] **Step 3: Add the parameters**

Replace the group-1 block in `modules/http_server/module.jai`:

```jai
#module_parameters (
    CACHE_LINE_SIZE     : s32 = 64,
    READ_BUFFER_SIZE    : s32 = 4096,
    MAX_HEADERS         : s32 = 64,
    MAX_FORM_VALUES     : s32 = 64,
    MAX_MULTIPART_PARTS : s32 = 16,
    LISTEN_BACKLOG      : s32 = 1024,
    // Cap on unsent response bytes one connection may queue when its socket is full. A tail that
    // would exceed it closes the connection (logged). Only slow readers ever hold a tail.
    MAX_PENDING_BYTES   : s64 = 1048576,
    // Timeouts in milliseconds; 0 disables each. See docs/plans/2026-10-03-fib-lifts-design.md §5.
    IDLE_TIMEOUT_MS     : s64 = 60000,    // kept-alive connection between requests
    HEADER_TIMEOUT_MS   : s64 = 10000,    // from a request's first byte until its headers are complete
    BODY_TIMEOUT_MS     : s64 = 30000,    // from a request's first byte until its body is complete
    WRITE_TIMEOUT_MS    : s64 = 30000     // a pending response making no progress toward the peer
)(
    // Program-wide (set-once) type of the per-request bound state handed to handlers via
    // `context.handler_data`. Default `void` => `*void` (fully generic). A consumer can
    // inject a concrete type for cast-free, type-safe handler state. Must live in this
    // second (program) group: there is one Context type per program, so the type of the
    // `#add_context handler_data` field cannot vary per-import.
    Handler_Data : Type = void
);
```

- [ ] **Step 4: Add `Parse_Error` to `http.jai`**

Directly after the `Parse_Result` enum:

```jai
// Why parse_request returned .ERROR; decides the canned reply (400 vs 413).
Parse_Error :: enum u8 #specified {
    NONE           :: 0;
    MALFORMED      :: 1;
    BODY_TOO_LARGE :: 2;
}
```

- [ ] **Step 5: Rewrite `connection.jai`**

```jai

Connection_State :: enum u8 #specified {
    FREE   :: 0;
    ACTIVE :: 1;
}

Connection :: struct {
    state:        Connection_State;
    fd:           s32 = -1;
    instance:     u8;
    next_free:    *Connection;      // Valid when state == .FREE

    // Per-connection read buffer and incremental parser state
    buf:          [READ_BUFFER_SIZE] u8;
    bytes_used:   s64;
    parse_offset: s64;
    parse_state:  Parse_State;
    parse_error:  Parse_Error;      // Why parse_request returned .ERROR
    req:          Request;

    // Send path, slow path only. `pending` holds response bytes the kernel did not take. Its
    // allocator is pinned to the heap in init_pool: the request Pool and temporary storage are
    // both reset underneath a stalled response, so neither may back this buffer.
    pending:          [..] u8;
    pending_offset:   s64;      // bytes of `pending` already handed to the kernel
    close_after_send: bool;     // close once `pending` drains
    read_stalled:     bool;     // read buffer filled while output was pending; re-read after drain

    // Timeouts: monotonic milliseconds from now_ms() in server.jai
    last_activity_ms: s64;      // accept, or the last successful read / write progress
    request_start_ms: s64;      // first byte of the request being parsed; 0 while idle or dispatching
}

Connection_Pool :: struct {
    connections:  [] Connection;
    free_list:    *Connection;    // Head of singly-linked free list
    free_count:   s64;
    total:        s64;
    data_to_free: *void;
}

init_pool :: (pool: *Connection_Pool, count: s64) {
    Basic.assert(count > 0, "Connection pool size must be > 0");
    pool.connections, pool.data_to_free = Basic.NewArray(count, Connection, true);
    pool.total = count;

    // Build free list: push in reverse so index 0 is at the head
    pool.free_list = null;
    i := count - 1;
    while i >= 0 {
        c := *pool.connections[i];
        c.state = .FREE;
        c.next_free = pool.free_list;
        c.fd = -1;
        c.instance = 0;
        // Pin the slow-path buffer to whatever allocator is current at init (the heap). Dispatch
        // runs under the per-request Pool, which must never back bytes that outlive a request.
        c.pending.allocator = context.allocator;
        pool.free_list = c;
        i -= 1;
    }
    pool.free_count = count;
}

destroy_pool :: (pool: *Connection_Pool) {
    for * pool.connections  release_pending(it);
    if pool.data_to_free {
        Basic.free(pool.data_to_free);
        pool.data_to_free = null;
    }
    pool.free_list = null;
    pool.free_count = 0;
    pool.total = 0;
}

// Pop a connection from the free list, mark it ACTIVE, flip instance bit.
get_connection :: (pool: *Connection_Pool) -> *Connection {
    c := pool.free_list;
    if c == null return null;

    pool.free_list = c.next_free;
    pool.free_count -= 1;

    c.state = .ACTIVE;
    c.instance ^= 1;
    c.bytes_used = 0;
    c.parse_offset = 0;
    c.parse_state = .REQUEST_LINE;
    c.parse_error = .NONE;
    c.req.header_count = 0;
    c.req.keep_alive = false;
    c.req.content_length = 0;

    release_pending(c);
    c.close_after_send = false;
    c.read_stalled     = false;
    c.last_activity_ms = 0;
    c.request_start_ms = 0;

    return c;
}

// Push a connection back onto the free list.
free_connection :: (pool: *Connection_Pool, c: *Connection) {
    Basic.assert(c != null, "Cannot free null connection");
    release_pending(c);
    c.fd = -1;
    c.state = .FREE;
    c.next_free = pool.free_list;
    pool.free_list = c;
    pool.free_count += 1;
}

// Free the queued tail and reset the cursor. Keeps the pinned allocator. Idempotent.
release_pending :: (c: *Connection) {
    if c.pending.data  Basic.array_free(c.pending);
    c.pending.data      = null;
    c.pending.count     = 0;
    c.pending.allocated = 0;
    c.pending_offset    = 0;
}

// Append raw bytes to a resizable byte array using the array's own allocator.
append_bytes :: (arr: *[..] u8, data: *u8, count: s64) {
    if count <= 0  return;
    Basic.array_reserve(arr, arr.count + count);
    memcpy(arr.data + arr.count, data, count);
    arr.count += count;
}
```

- [ ] **Step 6: Run the tests**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: `PASS: test_pending_defaults_and_release` and every other suite green. If `array_reserve` ignores the pinned allocator in your version (the test's second allocator assert fails after `append_bytes`), replace the `Basic.array_reserve` call with a manual grow: allocate `new_cap` bytes with `Basic.alloc(new_cap,, allocator = arr.allocator)`, `memcpy` the old contents, free the old block with the same allocator, and set `arr.allocated`.

- [ ] **Step 7: Commit**

```bash
git add modules/http_server/module.jai modules/http_server/connection.jai modules/http_server/http.jai modules/http_server/tests/test.jai
git commit -m "http_server: pending-output state, timeout stamps, new module params"
```

---

### Task 3: The writer — `write_response`, `flush_pending`, canned replies

**Files:**
- Modify: `modules/http_server/http.jai` (replace `write_response` and `send_all`, lines 181-222 and 334-347; extend `status_text`)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Consumes: `Connection` fields and `append_bytes`/`release_pending` from Task 2.
- Produces:
  - `Write_Result :: enum u8 #specified { SENT :: 0; PENDING :: 1; ERROR :: 2; }`
  - `write_response :: (c: *Connection, req: *Request, response: *Response, date: string) -> Write_Result`
  - `flush_pending :: (c: *Connection) -> Write_Result`
  - `build_response_header :: (req: *Request, response: *Response, date: string, body_count: s64) -> string`
  - `status_has_body :: (code: u16) -> bool`
  - `canned_response :: (status: u16) -> string`, `send_canned :: (fd: s32, status: u16)`
- Removes: `send_all`, the old `write_response(fd, response, keep_alive)`.

- [ ] **Step 1: Add the socket test helpers**

Append to the test file (before the tests, after the existing helpers section near the top is fine):

```jai
// -- Socket helpers for the send-path tests --
//
// A connected AF_UNIX pair. fds[0] is the server side (non-blocking), fds[1] the peer. A small
// SO_SNDBUF on the server side makes the kernel refuse bytes early, which is how these tests
// force the pending path deterministically, without sleeping.
make_socket_pair :: (server_sndbuf: s32 = 0) -> (server: s32, peer: s32) {
    fds: [2] s32;
    r := socketpair(AF_UNIX, .SOCK_STREAM | .SOCK_NONBLOCK | .SOCK_CLOEXEC, 0, *fds);
    assert(r == 0, "socketpair failed: %", errno());
    if server_sndbuf > 0 {
        v := server_sndbuf;
        r = setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, xx *v, size_of(type_of(v)));
        assert(r == 0, "setsockopt SO_SNDBUF failed: %", errno());
    }
    return fds[0], fds[1];
}

// Read everything the peer can see right now (until EAGAIN or EOF), appending to `into`.
drain_peer :: (peer: s32, into: *[..] u8) -> s64 {
    chunk: [16384] u8;
    got: s64 = 0;
    while true {
        n := read(peer, chunk.data, xx chunk.count);
        if n > 0 { append_bytes(into, chunk.data, n); got += n; continue; }
        if n == 0  return got;
        err := errno();
        if err == EINTR  continue;
        assert(err == EAGAIN || err == EWOULDBLOCK, "unexpected read error on peer: %", err);
        return got;
    }
}

as_string :: (arr: [..] u8) -> string {
    s: string;
    s.data  = arr.data;
    s.count = arr.count;
    return s;
}

starts_with :: (s: string, prefix: string) -> bool {
    if s.count < prefix.count  return false;
    for i: 0..prefix.count - 1  if s[i] != prefix[i]  return false;
    return true;
}

contains :: (haystack: string, needle: string) -> bool {
    return find_index_from_left(haystack, needle) >= 0;
}

count_occurrences :: (s: string, needle: string) -> s64 {
    n: s64 = 0;
    pos: s64 = 0;
    while pos + needle.count <= s.count {
        rest: string;
        rest.data  = s.data + pos;
        rest.count = s.count - pos;
        i := find_index_from_left(rest, needle);
        if i < 0  break;
        n += 1;
        pos += i + needle.count;
    }
    return n;
}

count_byte :: (s: string, b: u8) -> s64 {
    n: s64 = 0;
    for i: 0..s.count - 1  if s[i] == b  n += 1;
    return n;
}

// A Connection outside any pool with its pending allocator pinned, for writer-level tests.
standalone_connection :: (fd: s32) -> *Connection {
    c := New(Connection);
    c.pending.allocator = context.allocator;
    c.fd = fd;
    return c;
}

big_body :: (count: s64) -> string {
    s := alloc_string(count);
    memset(s.data, #char "x", count);
    return s;
}
```

Add `#import "Socket";` and `#import "POSIX";` at the bottom of the test file next to the existing imports.

- [ ] **Step 2: Write the failing writer tests**

```jai
// -- Writer (Task 3) --

test_write_response_full_send :: () {
    server, peer := make_socket_pair();
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer free(c);

    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 200, body = "Hello" };
    r := write_response(c, *req, *resp, "");
    assert(r == .SENT, "small response should be SENT, got %", r);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    out := as_string(got);
    assert(starts_with(out, "HTTP/1.1 200 OK\r\n"), "status line, got '%'", out);
    assert(contains(out, "Content-Type: text/plain\r\n"), "content type, got '%'", out);
    assert(contains(out, "Content-Length: 5\r\n"), "content length, got '%'", out);
    assert(!contains(out, "Connection:"), "HTTP/1.1 keep-alive must not spell out Connection, got '%'", out);
    assert(!contains(out, "Date:"), "an empty date must omit the Date header");
    assert(contains(out, "\r\n\r\nHello"), "body follows the blank line, got '%'", out);
    print("  PASS: test_write_response_full_send\n");
}

test_write_response_partial_goes_pending_then_drains :: () {
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer { release_pending(c); free(c); }

    body := big_body(262144);   // 256 KB, far past any SO_SNDBUF
    defer free(body);
    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 200, body = body };

    r := write_response(c, *req, *resp, "");
    assert(r == .PENDING, "256 KB into a 4 KB send buffer must go PENDING, got %", r);
    assert(c.pending.count > 0 && c.pending.count < body.count + 256, "a tail should be queued, got % bytes", c.pending.count);

    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while r == .PENDING {
        drain_peer(peer, *got);
        r = flush_pending(c);
        rounds += 1;
        assert(rounds < 100000, "flush never completed");
    }
    assert(r == .SENT, "flush should finish SENT, got %", r);
    assert(c.pending.count == 0 && c.pending.data == null, "pending must be released after SENT");
    drain_peer(peer, *got);

    out := as_string(got);
    header_end := find_index_from_left(out, "\r\n\r\n");
    assert(header_end >= 0, "header terminator missing");
    received_body := out.count - (header_end + 4);
    assert(received_body == body.count, "peer must receive the whole body: % of %", received_body, body.count);
    assert(count_byte(out, #char "x") == body.count, "body bytes intact");
    print("  PASS: test_write_response_partial_goes_pending_then_drains\n");
}

test_write_response_cap_exceeded :: () {
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer free(c);

    body := big_body(2 * 1048576);   // 2 MB tail > MAX_PENDING_BYTES default of 1 MB
    defer free(body);
    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 200, body = body };

    r := write_response(c, *req, *resp, "");
    assert(r == .ERROR, "a tail past MAX_PENDING_BYTES must be an ERROR, got %", r);
    assert(c.pending.count == 0, "nothing may be queued on ERROR, got %", c.pending.count);
    print("  PASS: test_write_response_cap_exceeded\n");
}

test_flush_pending_peer_gone :: () {
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(server);
    c := standalone_connection(server);
    defer { release_pending(c); free(c); }

    body := big_body(262144);
    defer free(body);
    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 200, body = body };
    r := write_response(c, *req, *resp, "");
    assert(r == .PENDING, "setup: expected PENDING, got %", r);

    close(peer);   // the client leaves with a tail still queued; must not raise SIGPIPE
    r = flush_pending(c);
    assert(r == .ERROR, "flushing to a closed peer must be ERROR, got %", r);
    print("  PASS: test_flush_pending_peer_gone\n");
}

test_write_response_head_sends_no_body :: () {
    server, peer := make_socket_pair();
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer free(c);

    req  := Request.{ method = "HEAD", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 200, body = "Hello" };
    r := write_response(c, *req, *resp, "");
    assert(r == .SENT, "HEAD response should be SENT, got %", r);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    out := as_string(got);
    assert(contains(out, "Content-Length: 5\r\n"), "HEAD keeps the GET length, got '%'", out);
    assert(out.count == find_index_from_left(out, "\r\n\r\n") + 4, "HEAD must send nothing after the headers, got '%'", out);
    print("  PASS: test_write_response_head_sends_no_body\n");
}

test_write_response_204_is_bodiless :: () {
    server, peer := make_socket_pair();
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer free(c);

    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 204, body = "ignored" };
    r := write_response(c, *req, *resp, "");
    assert(r == .SENT, "204 should be SENT, got %", r);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    out := as_string(got);
    assert(starts_with(out, "HTTP/1.1 204 No Content\r\n"), "status line, got '%'", out);
    assert(!contains(out, "Content-Length"), "204 must not carry Content-Length, got '%'", out);
    assert(!contains(out, "Content-Type"), "204 must not carry Content-Type, got '%'", out);
    assert(out.count == find_index_from_left(out, "\r\n\r\n") + 4, "204 must send no body, got '%'", out);
    print("  PASS: test_write_response_204_is_bodiless\n");
}

test_write_response_connection_header_rules :: () {
    server, peer := make_socket_pair();
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer free(c);
    got: [..] u8;
    defer array_free(got);

    // Closing: spelled out whatever the version.
    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = false };
    resp := Response.{ status_code = 200, body = "x" };
    write_response(c, *req, *resp, "");
    drain_peer(peer, *got);
    assert(contains(as_string(got), "Connection: close\r\n"), "close must be explicit, got '%'", as_string(got));

    // HTTP/1.0 keep-alive: the only keep-alive case that is spelled out.
    got.count = 0;
    req = Request.{ method = "GET", http_version = "HTTP/1.0", keep_alive = true };
    write_response(c, *req, *resp, "");
    drain_peer(peer, *got);
    assert(contains(as_string(got), "Connection: keep-alive\r\n"), "HTTP/1.0 keep-alive must be explicit, got '%'", as_string(got));
    print("  PASS: test_write_response_connection_header_rules\n");
}

test_write_response_date_header :: () {
    server, peer := make_socket_pair();
    defer close(server);
    defer close(peer);
    c := standalone_connection(server);
    defer free(c);

    req  := Request.{ method = "GET", http_version = "HTTP/1.1", keep_alive = true };
    resp := Response.{ status_code = 200, body = "x" };
    write_response(c, *req, *resp, "Sun, 06 Nov 1994 08:49:37 GMT");
    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(contains(as_string(got), "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"), "Date header verbatim, got '%'", as_string(got));
    print("  PASS: test_write_response_date_header\n");
}

test_canned_responses :: () {
    assert(starts_with(canned_response(400), "HTTP/1.1 400 Bad Request\r\n"), "400");
    assert(starts_with(canned_response(408), "HTTP/1.1 408 Request Timeout\r\n"), "408");
    assert(starts_with(canned_response(413), "HTTP/1.1 413 Payload Too Large\r\n"), "413");
    assert(starts_with(canned_response(431), "HTTP/1.1 431 Request Header Fields Too Large\r\n"), "431");
    assert(contains(canned_response(431), "Connection: close\r\n\r\n"), "canned replies close");

    server, peer := make_socket_pair();
    defer close(server);
    defer close(peer);
    send_canned(server, 413);
    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(string_equals(as_string(got), canned_response(413)), "send_canned writes the reply verbatim");
    print("  PASS: test_canned_responses\n");
}
```

Register in `main` after the send-path state group:

```jai
    print("\nWriter:\n");
    test_write_response_full_send();
    test_write_response_partial_goes_pending_then_drains();
    test_write_response_cap_exceeded();
    test_flush_pending_peer_gone();
    test_write_response_head_sends_no_body();
    test_write_response_204_is_bodiless();
    test_write_response_connection_header_rules();
    test_write_response_date_header();
    test_canned_responses();
```

- [ ] **Step 3: Run to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile error, `write_response` called with the wrong argument count (the old signature is `(fd, response, keep_alive)`).

- [ ] **Step 4: Replace the writer in `http.jai`**

Delete the old `write_response` and `send_all`. Add, in the public section (above `#scope_module`):

```jai
Write_Result :: enum u8 #specified {
    SENT    :: 0;   // every byte reached the kernel
    PENDING :: 1;   // a tail is queued in c.pending; wait for EPOLLOUT
    ERROR   :: 2;   // the peer is gone or MAX_PENDING_BYTES was exceeded; the caller closes
}

// 1xx, 204 and 304 carry neither a body nor the body-describing headers (RFC 9110 §6.4.1, §8.6).
status_has_body :: inline (code: u16) -> bool {
    return code >= 200 && code != 204 && code != 304;
}

// Serialize the status line and headers from context.allocator (the per-request Pool during
// dispatch). `body_count` is what Content-Length reports; for HEAD that is the GET body's
// length even though no body is sent. An empty `date` omits the Date header.
build_response_header :: (req: *Request, response: *Response, date: string, body_count: s64) -> string {
    builder: Basic.String_Builder;
    builder.allocator = context.allocator;
    Basic.print_to_builder(*builder, "HTTP/1.1 % %\r\n", response.status_code, status_text(response.status_code));
    if date.count > 0  Basic.print_to_builder(*builder, "Date: %\r\n", date);
    if status_has_body(response.status_code) {
        Basic.print_to_builder(*builder, "Content-Type: %\r\nContent-Length: %\r\n", response.content_type, body_count);
    }
    // HTTP/1.1 keeps alive by default, so only the exceptions are spelled out.
    if !req.keep_alive {
        Basic.append(*builder, "Connection: close\r\n");
    } else if string_equals(req.http_version, "HTTP/1.0") {
        Basic.append(*builder, "Connection: keep-alive\r\n");
    }
    for i: 0..cast(s64) response.header_count - 1 {
        Basic.print_to_builder(*builder, "%: %\r\n", response.headers[i].name, response.headers[i].value);
    }
    Basic.append(*builder, "\r\n");
    return Basic.builder_to_string(*builder,, allocator = context.allocator);
}

// Serialize and write a response: one sendmsg of [header, body], MSG_NOSIGNAL so a client that
// reset the connection yields EPIPE instead of killing the process. What the kernel does not
// take is copied into c.pending (heap) before the per-request Pool backing header and body is
// reset by the caller. HEAD and bodiless statuses send the header only.
write_response :: (c: *Connection, req: *Request, response: *Response, date: string) -> Write_Result {
    is_head   := string_equals(req.method, "HEAD");
    send_body := response.body.count > 0 && !is_head && status_has_body(response.status_code);
    header := build_response_header(req, response, date, response.body.count);
    body: string;
    if send_body  body = response.body;

    iov: [2] iovec;
    iov[0].iov_base = cast(*void) header.data;
    iov[0].iov_len  = xx header.count;
    iov[1].iov_base = cast(*void) body.data;
    iov[1].iov_len  = xx body.count;
    msg: msghdr;
    msg.msg_iov    = iov.data;
    msg.msg_iovlen = ifx body.count > 0 then cast(u64) 2 else cast(u64) 1;

    total := header.count + body.count;
    sent: s64 = 0;
    while true {
        n := sendmsg(c.fd, *msg, .NOSIGNAL);
        if n >= 0 { sent = n; break; }
        err := errno();
        if err == EINTR  continue;
        if err == EAGAIN || err == EWOULDBLOCK  break;        // sent stays 0: queue everything
        if err == EPIPE  || err == ECONNRESET   return .ERROR; // the client left; not our failure
        Basic.log_error("sendmsg failed on fd %: errno %", c.fd, err);
        return .ERROR;
    }
    if sent == total  return .SENT;

    // Slow path: the socket is full. Header and body live in per-request memory, so the unsent
    // tail is copied into c.pending now, before the worker resets the Pool.
    unsent := total - sent;
    if unsent > MAX_PENDING_BYTES {
        Basic.log("fd %: unsent response tail of % bytes exceeds MAX_PENDING_BYTES (%); closing", c.fd, unsent, MAX_PENDING_BYTES);
        return .ERROR;
    }
    header_sent := ifx sent < header.count then sent else header.count;
    body_sent   := sent - header_sent;
    append_bytes(*c.pending, header.data + header_sent, header.count - header_sent);
    append_bytes(*c.pending, body.data   + body_sent,   body.count   - body_sent);
    return .PENDING;
}

// Push the queued tail toward the kernel. SENT frees the buffer.
flush_pending :: (c: *Connection) -> Write_Result {
    while c.pending_offset < c.pending.count {
        remaining := c.pending.count - c.pending_offset;
        n := send(c.fd, c.pending.data + c.pending_offset, xx remaining, .NOSIGNAL);
        if n > 0 { c.pending_offset += n; continue; }
        if n == 0 {
            Basic.log_error("send returned 0 on fd % with % bytes pending", c.fd, remaining);
            return .ERROR;
        }
        err := errno();
        if err == EINTR  continue;
        if err == EAGAIN || err == EWOULDBLOCK  return .PENDING;
        if err == EPIPE  || err == ECONNRESET   return .ERROR;
        Basic.log_error("send failed on fd %: errno %", c.fd, err);
        return .ERROR;
    }
    release_pending(c);
    return .SENT;
}

// Static replies for requests the server refuses before a handler runs. Connection: close always.
canned_response :: (status: u16) -> string {
    if status == {
        case 400; return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        case 408; return "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        case 413; return "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        case 431; return "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        case;     return "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    }
}

// One attempt, never queued: the connection is closing either way and the reply is tiny.
send_canned :: (fd: s32, status: u16) {
    s := canned_response(status);
    while true {
        n := send(fd, s.data, xx s.count, .NOSIGNAL);
        if n >= 0 || errno() != EINTR  break;
    }
}
```

Extend `status_text` with two cases, in numeric order:

```jai
        case 408; return "Request Timeout";
        case 431; return "Request Header Fields Too Large";
```

`server.jai` no longer compiles at this point because it calls the old signature; that is expected and fixed in Task 4. To keep this task independently green, make the minimal edit in `server.jai` line 294 now:

```jai
                        write_response(c, *c.req, *response, "");
```

(the result is ignored until Task 4 rewires the loop).

- [ ] **Step 5: Run the tests**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: all nine new writer tests `PASS`, all other suites green. If `test_flush_pending_peer_gone` kills the process with `SIGPIPE`, a `send` call lost its `.NOSIGNAL` flag.

- [ ] **Step 6: Commit**

```bash
git add modules/http_server/http.jai modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: writer reports SENT/PENDING/ERROR, queues the unsent tail, MSG_NOSIGNAL everywhere"
```

---

### Task 4: Event loop — permanent EPOLLOUT, flush → read → hangup

**Files:**
- Modify: `modules/http_server/server.jai` (`Worker` struct; `accept_connections`, `handle_client`, `close_connection`; move seams above `#scope_file`)
- Modify: `modules/http_server/http.jai` (`parse_request` sets `parse_error`)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Consumes: `write_response`, `flush_pending`, `send_canned` (Task 3); `Connection` fields (Task 2).
- Produces (all exported, above `#scope_file`):
  - `now_ms :: () -> s64`
  - `handle_client :: (w: *Worker, c: *Connection, events: u32)`
  - `read_and_dispatch :: (w: *Worker, c: *Connection) -> bool` (false = connection closed)
  - `dispatch_buffered :: (w: *Worker, c: *Connection) -> bool` (false = connection closed)
  - `refuse_and_close :: (w: *Worker, c: *Connection, status: u16)`
  - `close_connection :: (w: *Worker, c: *Connection)`, `accept_connections :: (w: *Worker)`
  - `Worker.date: string` (empty until Task 7 fills it)

- [ ] **Step 1: Write the failing tests**

Fake-worker helpers, appended to the test file after the socket helpers:

```jai
// -- Fake worker for event-handling tests --

test_handler_calls: s32;

ok_handler :: (req: *Request, resp: *Response) {
    test_handler_calls += 1;
    resp.status_code = 200;
    resp.body = "ok";
}

big_test_body: string;

big_handler :: (req: *Request, resp: *Response) {
    test_handler_calls += 1;
    resp.status_code = 200;
    resp.body = big_test_body;
}

make_test_worker :: (w: *Worker, handler: Handler) {
    ok := init_event_engine(*w.engine);
    assert(ok, "init_event_engine failed");
    init_pool(*w.pool, 4);
    set_allocators(*w.request_pool);
    w.handler      = handler;
    w.handler_data = null;
    test_handler_calls = 0;
}

destroy_test_worker :: (w: *Worker) {
    destroy_event_engine(*w.engine);
    destroy_pool(*w.pool);
    release(*w.request_pool);
}

// Register a server-side fd as a live connection on the fake worker, as accept_connections would.
attach :: (w: *Worker, fd: s32) -> *Connection {
    c := get_connection(*w.pool);
    assert(c != null, "pool exhausted");
    c.fd = fd;
    c.last_activity_ms = now_ms();
    ok := epoll_add_connection(*w.engine, c, EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP);
    assert(ok, "epoll_add_connection failed");
    return c;
}

send_to_server :: (peer: s32, s: string) {
    n := write(peer, s.data, xx s.count);
    assert(n == s.count, "short write from peer: % of %", n, s.count);
}
```

Add `#import "Pool";` (for `set_allocators` and `release`) and `#import "Linux";` (for the `EPOLL*` constants; a module's own imports are not re-exported to its importers) next to the other test imports.

The tests:

```jai
// -- Event handling (Task 4) --

test_handle_client_answers_before_honoring_rdhup :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    shutdown(peer, .WR);   // request and FIN together: IN and RDHUP arrive in one event

    handle_client(*w, c, EPOLLIN | EPOLLRDHUP);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    out := as_string(got);
    assert(test_handler_calls == 1, "handler must run once, ran %", test_handler_calls);
    assert(starts_with(out, "HTTP/1.1 200 OK"), "the request must be answered before the close, got '%'", out);
    assert(c.state == .FREE, "connection closes after the response");
    print("  PASS: test_handle_client_answers_before_honoring_rdhup\n");
}

test_handle_client_pending_blocks_dispatch :: () {
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, big_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    handle_client(*w, c, EPOLLIN);
    assert(c.pending.count > 0, "the first response must stall");
    assert(test_handler_calls == 1, "the second request must wait for the drain; handler ran % times", test_handler_calls);

    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while test_handler_calls < 2 || c.pending.count > 0 {
        drain_peer(peer, *got);
        handle_client(*w, c, EPOLLOUT);
        rounds += 1;
        assert(rounds < 100000, "never drained");
    }
    drain_peer(peer, *got);
    out := as_string(got);
    assert(test_handler_calls == 2, "both requests served, got %", test_handler_calls);
    assert(count_occurrences(out, "HTTP/1.1 200 OK\r\n") == 2, "two responses on the wire, got '%'", count_occurrences(out, "HTTP/1.1 200 OK\r\n"));
    assert(count_byte(out, #char "x") == 2 * big_test_body.count, "both bodies intact and in full");
    assert(c.state == .ACTIVE, "keep-alive connection stays open");
    close_connection(*w, c);
    print("  PASS: test_handle_client_pending_blocks_dispatch\n");
}

test_handle_client_full_buffer_while_pending_stalls_read :: () {
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, big_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);

    // One request, then enough pipelined requests to overflow the 4096-byte read buffer.
    one := "GET /a HTTP/1.1\r\nHost: x\r\n\r\n";
    send_to_server(peer, one);
    handle_client(*w, c, EPOLLIN);
    assert(c.pending.count > 0, "setup: first response must stall");
    for 1..300  send_to_server(peer, one);   // ~8 KB of requests behind the stalled response
    handle_client(*w, c, EPOLLIN);
    assert(c.state == .ACTIVE, "a full buffer behind pending output is not a 431");
    assert(c.read_stalled, "read must be marked stalled, not refused");
    assert(test_handler_calls == 1, "nothing dispatched while pending, got %", test_handler_calls);

    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while test_handler_calls < 301 || c.pending.count > 0 {
        drain_peer(peer, *got);
        handle_client(*w, c, EPOLLOUT);
        rounds += 1;
        assert(rounds < 1000000, "never drained; handler calls = %", test_handler_calls);
    }
    assert(test_handler_calls == 301, "every pipelined request is eventually served, got %", test_handler_calls);
    close_connection(*w, c);
    print("  PASS: test_handle_client_full_buffer_while_pending_stalls_read\n");
}

test_handle_client_oversized_header_gets_431 :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    pad := big_body(5000);   // one header line longer than READ_BUFFER_SIZE, no terminator
    defer free(pad);
    send_to_server(peer, "GET / HTTP/1.1\r\nX-Pad: ");
    send_to_server(peer, pad);
    handle_client(*w, c, EPOLLIN);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(starts_with(as_string(got), "HTTP/1.1 431 "), "oversized header gets 431, got '%'", as_string(got));
    assert(c.state == .FREE && test_handler_calls == 0, "refused and closed without a handler run");
    print("  PASS: test_handle_client_oversized_header_gets_431\n");
}

test_handle_client_oversized_body_gets_413 :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n");
    handle_client(*w, c, EPOLLIN);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(starts_with(as_string(got), "HTTP/1.1 413 "), "a body past the read buffer gets 413, got '%'", as_string(got));
    assert(c.state == .FREE && test_handler_calls == 0, "refused and closed without a handler run");
    print("  PASS: test_handle_client_oversized_body_gets_413\n");
}

test_handle_client_malformed_gets_400 :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "GARBAGE\r\n\r\n");
    handle_client(*w, c, EPOLLIN);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(starts_with(as_string(got), "HTTP/1.1 400 "), "a malformed request line gets 400, got '%'", as_string(got));
    assert(c.state == .FREE && test_handler_calls == 0, "refused and closed without a handler run");
    print("  PASS: test_handle_client_malformed_gets_400\n");
}

test_handle_client_out_with_nothing_queued_is_ignored :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    handle_client(*w, c, EPOLLOUT);   // the registration edge: nothing to do
    assert(c.state == .ACTIVE && test_handler_calls == 0, "a spurious OUT must change nothing");
    close_connection(*w, c);
    print("  PASS: test_handle_client_out_with_nothing_queued_is_ignored\n");
}

test_parse_error_classification :: () {
    c: Connection;
    bad := "GARBAGE\r\n\r\n";
    memcpy(c.buf.data, bad.data, bad.count);
    c.bytes_used = bad.count;
    assert(parse_request(*c) == .ERROR && c.parse_error == .MALFORMED, "no spaces in the request line is MALFORMED");

    c2: Connection;
    big := "POST / HTTP/1.1\r\nContent-Length: 100000\r\n\r\n";
    memcpy(c2.buf.data, big.data, big.count);
    c2.bytes_used = big.count;
    assert(parse_request(*c2) == .ERROR && c2.parse_error == .BODY_TOO_LARGE, "Content-Length past the buffer is BODY_TOO_LARGE");
    print("  PASS: test_parse_error_classification\n");
}
```

Register in `main`:

```jai
    print("\nEvent handling:\n");
    test_parse_error_classification();
    test_handle_client_out_with_nothing_queued_is_ignored();
    test_handle_client_answers_before_honoring_rdhup();
    test_handle_client_pending_blocks_dispatch();
    test_handle_client_full_buffer_while_pending_stalls_read();
    test_handle_client_oversized_header_gets_431();
    test_handle_client_oversized_body_gets_413();
    test_handle_client_malformed_gets_400();
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile error, `handle_client` is not visible (it is under `#scope_file`) or `now_ms` undeclared.

- [ ] **Step 3: Classify parse errors in `http.jai`**

In `parse_request`, every `return .ERROR;` sets the cause first. The two in the request-line and header sections become:

```jai
        if sp1 < 0 { c.parse_error = .MALFORMED; return .ERROR; }
```
```jai
        if sp2 < 0 { c.parse_error = .MALFORMED; return .ERROR; }
```
```jai
            if colon < 0 { c.parse_error = .MALFORMED; return .ERROR; }
```

and the Content-Length block becomes:

```jai
                if has_cl {
                    cl := parse_s64(cl_str);
                    if cl < 0 { c.parse_error = .MALFORMED; return .ERROR; }
                    if cl > 0 {
                        max_body := cast(s64) READ_BUFFER_SIZE - c.parse_offset;
                        if cl > max_body { c.parse_error = .BODY_TOO_LARGE; return .ERROR; }   // Body won't fit in buffer
                        c.req.content_length = cl;
                        c.parse_state = .BODY;
                        break;  // Fall through to BODY check below
                    }
                }
```

The final fallthrough `return .ERROR;` at the bottom of `parse_request` becomes:

```jai
    c.parse_error = .MALFORMED;
    return .ERROR;
```

- [ ] **Step 4: Rewrite the connection handling in `server.jai`**

Add `date: string;` to `Worker` (after `request_pool`). Then replace everything from `accept_connections` through `close_connection` with the block below, and move the `#scope_file` line so that only `worker_thread_proc`, `worker_listen`, `worker_run` and `destroy_worker` remain file-scoped (place the new procs **above** `#scope_file`, after `server_run`).

```jai
// Monotonic milliseconds for the timeout stamps.
now_ms :: inline () -> s64 {
    return cast(s64) (Basic.seconds_since_init() * 1000.0);
}

accept_connections :: (w: *Worker) {
    while true {
        addr: sockaddr_in;
        addrlen: u32 = size_of(sockaddr_in);
        conn_fd := accept4(w.listen_fd, cast(*sockaddr) *addr, xx *addrlen, .NONBLOCK | .CLOEXEC);

        if conn_fd < 0 break;  // EAGAIN — no more pending

        // Disable Nagle's algorithm — send response bytes immediately
        nodelay: s32 = 1;
        setsockopt(conn_fd, xx IPPROTO.TCP, TCP_NODELAY, xx *nodelay, size_of(type_of(nodelay)));

        c := get_connection(*w.pool);
        if c == null {
            Basic.log("fd %: connection pool exhausted; dropping", conn_fd);
            close(conn_fd);
            continue;
        }
        c.fd = conn_fd;
        c.last_activity_ms = now_ms();

        // Write interest is armed once for the connection's whole life. Edge-triggered OUT only
        // fires on the full-to-writable transition, so it costs nothing while there is room, and
        // a stalled response never needs an epoll_ctl MOD to be resumed.
        ok := epoll_add_connection(*w.engine, c, EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP);
        if !ok {
            close(conn_fd);
            free_connection(*w.pool, c);
        }
    }
}

handle_client :: (w: *Worker, c: *Connection, events: u32) {
    // 1. Output first. OUT also fires on registration and after every drain; with nothing
    //    queued it means nothing.
    if (events & EPOLLOUT) != 0 && c.pending.count > 0 {
        r := flush_pending(c);
        if r == .ERROR { close_connection(w, c); return; }
        c.last_activity_ms = now_ms();
        if r == .SENT {
            if c.close_after_send { close_connection(w, c); return; }
            // Drained: serve the requests the read buffer already holds, then re-read the socket
            // if the buffer had filled up while output was pending (no edge comes for those bytes).
            if !dispatch_buffered(w, c)  return;
            if c.read_stalled {
                c.read_stalled = false;
                if !read_and_dispatch(w, c)  return;
            }
        }
    }

    // 2. Input next, so a request that arrived together with the peer's FIN is still answered.
    if (events & EPOLLIN) != 0 {
        if !read_and_dispatch(w, c)  return;
    }

    // 3. Hangups last. ERR/HUP: the socket is unusable. RDHUP: the peer half-closed its write
    //    side and can still read a pending response.
    if (events & (EPOLLERR | EPOLLHUP)) != 0 { close_connection(w, c); return; }
    if (events & EPOLLRDHUP) != 0 {
        if c.pending.count > 0  c.close_after_send = true;
        else                    close_connection(w, c);
    }
}

// Read until EAGAIN (edge-triggered), dispatching complete requests as they land unless output
// is pending. Returns false when the connection was closed.
read_and_dispatch :: (w: *Worker, c: *Connection) -> bool {
    while true {
        available := READ_BUFFER_SIZE - c.bytes_used;
        if available <= 0 {
            if c.pending.count > 0 {
                // Pipelined requests are waiting behind a stalled response. The socket keeps the
                // rest; the drain re-reads it, since no new edge will announce bytes already there.
                c.read_stalled = true;
                return true;
            }
            // A full buffer with no complete request: the header block alone exceeds READ_BUFFER_SIZE.
            refuse_and_close(w, c, 431);
            return false;
        }

        n := read(c.fd, c.buf.data + c.bytes_used, xx available);
        if n < 0 {
            err := errno();
            if err == EAGAIN || err == EWOULDBLOCK  return true;
            if err == EINTR  continue;
            if err != ECONNRESET  Basic.log_error("read failed on fd %: errno %", c.fd, err);
            close_connection(w, c);
            return false;
        }
        if n == 0 {
            // EOF: answer whatever is complete, then close once any pending tail has gone.
            if !dispatch_buffered(w, c)  return false;
            if c.pending.count > 0 { c.close_after_send = true; return true; }
            close_connection(w, c);
            return false;
        }

        c.bytes_used += n;
        c.last_activity_ms = now_ms();
        if c.request_start_ms == 0  c.request_start_ms = c.last_activity_ms;
        if !dispatch_buffered(w, c)  return false;
    }
}

// Parse and serve every complete request in the read buffer. Stops, without reading more, as
// soon as a response goes PENDING. Returns false when the connection was closed.
dispatch_buffered :: (w: *Worker, c: *Connection) -> bool {
    while c.pending.count == 0 {
        result := parse_request(c);
        if result == .INCOMPLETE  return true;
        if result == .ERROR {
            status: u16 = ifx c.parse_error == .BODY_TOO_LARGE then 413 else 400;
            refuse_and_close(w, c, status);
            return false;
        }

        // COMPLETE. The request has fully arrived: no deadline bounds the handler.
        c.request_start_ms = 0;
        response: Response;
        wr: Write_Result;

        // Invoke the handler under the per-request pool allocator, with the handler's bound state
        // poked into the context. The core is routing-agnostic — for a routed server, w.handler is
        // router.jai's adapter. The response is written inside the same context so the header is
        // built from the Pool (never temporary storage), and any unsent tail is copied to the heap
        // before the Pool is reset below.
        new_ctx := context;
        new_ctx.allocator    = .{Pool_Module.pool_allocator_proc, *w.request_pool};
        new_ctx.handler_data = w.handler_data;
        push_context new_ctx {
            if w.handler  w.handler(*c.req, *response);
            wr = write_response(c, *c.req, *response, w.date);
        }
        Pool_Module.reset(*w.request_pool);   // recycle this request's Pool blocks (handler + header)
        c.last_activity_ms = now_ms();

        if wr == .ERROR { close_connection(w, c); return false; }
        keep_alive := c.req.keep_alive;
        reset_for_next_request(c);
        if wr == .PENDING {
            if !keep_alive  c.close_after_send = true;
            return true;    // dispatch resumes when EPOLLOUT drains the tail
        }
        if !keep_alive { close_connection(w, c); return false; }
    }
    return true;
}

// Answer a request the server will not serve with a canned status, then close.
refuse_and_close :: (w: *Worker, c: *Connection, status: u16) {
    Basic.log("fd %: refusing request with %", c.fd, status);
    send_canned(c.fd, status);
    close_connection(w, c);
}

close_connection :: (w: *Worker, c: *Connection) {
    epoll_del_connection(*w.engine, c);
    close(c.fd);
    free_connection(*w.pool, c);
}
```

In `reset_for_next_request` (`http.jai`), add at the end so a pipelined next request is timed from now:

```jai
    c.request_start_ms = ifx remaining > 0 then now_ms() else 0;
```

- [ ] **Step 5: Run the tests**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: the eight new event-handling tests `PASS`; all suites green.

- [ ] **Step 6: Build the examples and smoke one**

Run: `~/jai/jai/bin/jai-linux first.jai -`
Expected: all four examples build unchanged.

```bash
./build_debug/hello_world & sleep 1
curl -s -i http://localhost:9090/ | head -5
curl -s -i --http1.0 http://localhost:9090/ | grep -i connection
kill %1
```
Expected: `HTTP/1.1 200 OK` with no `Connection` header on the first; `Connection: close` on the second.

- [ ] **Step 7: Commit**

```bash
git add modules/http_server/server.jai modules/http_server/http.jai modules/http_server/tests/test.jai
git commit -m "http_server: permanent EPOLLOUT, flush/read/hangup ordering, dispatch pauses on pending output, canned 400/413/431"
```

---

### Task 5: Router — HEAD falls back to GET, 405 carries Allow

**Files:**
- Modify: `modules/http_router/trie.jai` (`find_endpoint`, `node_has_method`, `trie_match_rec`, `tree_match`; add `allow_header_for`)
- Modify: `modules/http_router/router.jai` (`dispatch`, `dispatch_with_middleware`)
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Produces: `tree_match(...) -> (handler: Route_Handler, status: Match_Status, allow: string)` (third value is empty unless `status == .METHOD_NOT_ALLOWED`); `allow_header_for :: (node: *Trie_Node) -> string`. Existing two-value call sites keep compiling: Jai lets a caller take fewer return values.

- [ ] **Step 1: Write the failing tests**

Append to the router test file:

```jai
// -- HEAD and Allow (Task 5) --

head_probe_calls: s32;
get_probe_calls:  s32;

head_probe_handler :: (req: *Request, resp: *Response) { head_probe_calls += 1; resp.status_code = 200; }
get_probe_handler  :: (req: *Request, resp: *Response) { get_probe_calls  += 1; resp.status_code = 200; resp.body = "get"; }

response_header :: (resp: *Response, name: string) -> (value: string, found: bool) {
    for i: 0..cast(s64) resp.header_count - 1 {
        if string_equals(resp.headers[i].name, name)  return resp.headers[i].value, true;
    }
    empty: string;
    return empty, false;
}

test_head_falls_back_to_get :: () {
    router: Router;
    get(*router, "/thing", get_probe_handler);
    req := Request.{ method = "HEAD", path = "/thing" };
    resp: Response;
    get_probe_calls = 0;
    dispatch(*router, *req, *resp);
    assert(resp.status_code == 200 && get_probe_calls == 1, "HEAD must be served by the GET route; status %, calls %", resp.status_code, get_probe_calls);
    assert(string_equals(resp.body, "get"), "the handler runs so Content-Length is right; the writer drops the body");
    print("  PASS: test_head_falls_back_to_get\n");
}

test_explicit_head_route_wins :: () {
    router: Router;
    get(*router, "/thing", get_probe_handler);
    head(*router, "/thing", head_probe_handler);
    req := Request.{ method = "HEAD", path = "/thing" };
    resp: Response;
    get_probe_calls = 0;
    head_probe_calls = 0;
    dispatch(*router, *req, *resp);
    assert(head_probe_calls == 1 && get_probe_calls == 0, "an explicit HEAD route beats the GET fallback; head %, get %", head_probe_calls, get_probe_calls);
    print("  PASS: test_explicit_head_route_wins\n");
}

test_405_carries_allow :: () {
    router: Router;
    get(*router, "/thing", get_probe_handler);
    post(*router, "/thing", get_probe_handler);
    req := Request.{ method = "PUT", path = "/thing" };
    resp: Response;
    dispatch(*router, *req, *resp);
    assert(resp.status_code == 405, "PUT on a GET/POST path is 405, got %", resp.status_code);
    allow, found := response_header(*resp, "Allow");
    assert(found, "405 must carry Allow");
    assert(string_equals(allow, "GET, POST, HEAD"), "Allow lists registered methods plus HEAD for GET, got '%'", allow);
    print("  PASS: test_405_carries_allow\n");
}

test_405_allow_without_get_has_no_head :: () {
    router: Router;
    post(*router, "/thing", get_probe_handler);
    req := Request.{ method = "GET", path = "/thing" };
    resp: Response;
    dispatch(*router, *req, *resp);
    assert(resp.status_code == 405, "GET on a POST-only path is 405, got %", resp.status_code);
    allow, found := response_header(*resp, "Allow");
    assert(found && string_equals(allow, "POST"), "no GET means no implied HEAD, got '%'", allow);
    print("  PASS: test_405_allow_without_get_has_no_head\n");
}

test_mount_405_carries_allow :: () {
    api: Router;
    get(*api, "/x", get_probe_handler);
    root: Router;
    mount(*root, "/api", *api);
    req := Request.{ method = "DELETE", path = "/api/x" };
    resp: Response;
    dispatch(*root, *req, *resp);
    assert(resp.status_code == 405, "mounted 405, got %", resp.status_code);
    allow, found := response_header(*resp, "Allow");
    assert(found && string_equals(allow, "GET, HEAD"), "mounted routers set Allow too, got '%'", allow);
    print("  PASS: test_mount_405_carries_allow\n");
}
```

Register in the router `main`:

```jai
    print("\nHEAD and Allow:\n");
    test_head_falls_back_to_get();
    test_explicit_head_route_wins();
    test_405_carries_allow();
    test_405_allow_without_get_has_no_head();
    test_mount_405_carries_allow();
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: `router_tests` fails at `test_head_falls_back_to_get` ("HEAD must be served by the GET route; status 405").

- [ ] **Step 3: HEAD fallback and `Allow` in `trie.jai`**

Replace `node_has_method` and `find_endpoint`:

```jai
node_has_method :: (node: *Trie_Node, method: string) -> bool {
    return find_endpoint(node, method) != null;
}

find_endpoint :: (node: *Trie_Node, method: string) -> *Trie_Endpoint {
    for * node.endpoints  if string_equals(it.method, method)  return it;   // exact method
    if string_equals(method, "HEAD") {
        for * node.endpoints  if string_equals(it.method, "GET")  return it;  // a GET route answers HEAD (RFC 9110 §9.3.2)
    }
    for * node.endpoints  if it.method.count == 0  return it;                 // then "any"
    return null;
}

// The Allow value for a 405 at this node: its registered methods in registration order, with
// HEAD appended whenever GET is registered and HEAD is not. Built from context.allocator, which
// during dispatch is the per-request Pool.
allow_header_for :: (node: *Trie_Node) -> string {
    builder: Basic.String_Builder;
    builder.allocator = context.allocator;
    has_get, has_head := false, false;
    for * node.endpoints {
        if it.method.count == 0  continue;   // an "any" endpoint would have matched; defensive
        if string_equals(it.method, "GET")   has_get  = true;
        if string_equals(it.method, "HEAD")  has_head = true;
        if Basic.builder_string_length(*builder) > 0  Basic.append(*builder, ", ");
        Basic.append(*builder, it.method);
    }
    if has_get && !has_head {
        if Basic.builder_string_length(*builder) > 0  Basic.append(*builder, ", ");
        Basic.append(*builder, "HEAD");
    }
    return Basic.builder_to_string(*builder,, allocator = context.allocator);
}
```

In `trie_match_rec`, replace the `saw_leaf: *bool` parameter with `leaf_405: *s32` (the first leaf reached whose methods did not match; `-1` when none), and replace the two `saw_leaf.* = true;` sites:

```jai
    if k == segs.count {
        if node.endpoints.count > 0 {
            if node_has_method(node, method)  return node_idx;
            if leaf_405.* == -1  leaf_405.* = node_idx;
        }
        return -1;
    }
```

and in the wildcard branch:

```jai
            if wnode.endpoints.count > 0 {
                if node_has_method(wnode, method)  return node.wildcard_child;
                if leaf_405.* == -1  leaf_405.* = node.wildcard_child;
            }
```

In `tree_match`, change the signature and the tail:

```jai
tree_match :: (t: *Trie, method: string, path: string, out_params: *[MAX_PARAMS] Param, out_count: *s32) -> (handler: Route_Handler, status: Match_Status, allow: string) {
    out_count.* = 0;
    null_handler: Route_Handler;
    no_allow: string;
    if t.nodes.count == 0  return null_handler, .NOT_FOUND, no_allow;
    ...                                                  // (unchanged: strip, split, segs)
    values: [MAX_PARAMS] string;
    vcount: s32 = 0;
    leaf_405: s32 = -1;

    leaf := trie_match_rec(t, 0, sp, segs, 0, method, *values, *vcount, *leaf_405);
    if leaf != -1 {
        ep := find_endpoint(*t.nodes[leaf], method);
        if ep != null {
            n := vcount;
            if n > cast(s32) ep.param_keys.count  n = cast(s32) ep.param_keys.count;
            for i: 0..n-1 {
                out_params.*[i] = .{ name = ep.param_keys[i], value = values[i] };
            }
            out_count.* = n;
            return ep.handler, .MATCHED, no_allow;
        }
    }
    if leaf_405 != -1  return null_handler, .METHOD_NOT_ALLOWED, allow_header_for(*t.nodes[leaf_405]);
    return null_handler, .NOT_FOUND, no_allow;
}
```

Fix the `-> (handler: Route_Handler, status: Match_Status)` mention and the `saw_leaf` names in the comments above `tree_match` and `trie_match_rec` to match.

- [ ] **Step 4: Set `Allow` in `router.jai`**

In `dispatch`, change the match call and the 405 branch:

```jai
    handler, status, allow := tree_match(*router.tree, req.method, req.path, *http_ctx.params, *http_ctx.param_count);
```
```jai
    if status == .METHOD_NOT_ALLOWED {
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
        set_header(resp, "Allow", allow);   // RFC 9110 §15.5.6: a 405 MUST carry Allow
        return;
    }
```

Make the identical two edits in `dispatch_with_middleware`.

- [ ] **Step 5: Run the tests**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: the five new router tests `PASS`; the existing `test_tm_404_405`, `test_dispatch_405` and `test_macro_head` still pass.

- [ ] **Step 6: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/router.jai modules/http_router/tests/test.jai
git commit -m "http_router: GET routes answer HEAD, 405 carries Allow"
```

---

### Task 6: Timeouts

**Files:**
- Modify: `modules/http_server/server.jai` (add the timeout procs above `#scope_file`; change `worker_run`)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Consumes: `Connection.last_activity_ms`, `request_start_ms`, `pending`, parameters from Task 2; `send_canned`, `close_connection`.
- Produces: `Timeout_State :: enum u8 #specified { NONE :: 0; IDLE :: 1; HEADER :: 2; BODY :: 3; WRITE :: 4; }`, `timeout_state :: (c: *Connection) -> Timeout_State`, `is_timed_out :: (c: *Connection, now: s64) -> (timed_out: bool, state: Timeout_State)`, `check_timeouts :: (w: *Worker, now: s64) -> s32` (connections closed).

- [ ] **Step 1: Write the failing tests**

```jai
// -- Timeouts (Task 6). Defaults asserted as literals: idle 60000, header 10000, body 30000, write 30000. --

test_timeout_state_classification :: () {
    c: Connection;
    assert(timeout_state(*c) == .IDLE, "empty buffer, nothing pending: IDLE");
    c.bytes_used = 5;
    c.parse_state = .REQUEST_LINE;
    assert(timeout_state(*c) == .HEADER, "bytes in the buffer before the headers end: HEADER");
    c.parse_state = .HEADERS;
    assert(timeout_state(*c) == .HEADER, "mid-headers: HEADER");
    c.parse_state = .BODY;
    assert(timeout_state(*c) == .BODY, "headers done, body incomplete: BODY");
    c.pending.count = 1;   // synthetic: a queued tail outranks everything
    assert(timeout_state(*c) == .WRITE, "pending output: WRITE");
    c.pending.count = 0;
    print("  PASS: test_timeout_state_classification\n");
}

test_is_timed_out_uses_the_right_clock :: () {
    c: Connection;
    c.last_activity_ms = 1000;
    t, s := is_timed_out(*c, 1000 + 59999);
    assert(!t && s == .IDLE, "idle one ms short of 60 s is fine");
    t, s = is_timed_out(*c, 1000 + 60000);
    assert(t && s == .IDLE, "idle at 60 s times out");

    c.bytes_used = 3;
    c.parse_state = .REQUEST_LINE;
    c.request_start_ms = 5000;
    c.last_activity_ms = 14990;   // recent activity does not rescue a slow header
    t, s = is_timed_out(*c, 5000 + 9999);
    assert(!t && s == .HEADER, "header one ms short of 10 s is fine");
    t, s = is_timed_out(*c, 5000 + 10000);
    assert(t && s == .HEADER, "header at 10 s times out, measured from the request start");

    c.parse_state = .BODY;
    t, s = is_timed_out(*c, 5000 + 29999);
    assert(!t && s == .BODY, "body one ms short of 30 s is fine");
    t, s = is_timed_out(*c, 5000 + 30000);
    assert(t && s == .BODY, "body at 30 s times out");
    print("  PASS: test_is_timed_out_uses_the_right_clock\n");
}

test_is_timed_out_write_then_idle :: () {
    c: Connection;
    c.pending.count = 1;          // synthetic tail
    c.last_activity_ms = 1000;    // last write progress
    c.request_start_ms = 0;
    t, s := is_timed_out(*c, 1000 + 29999);
    assert(!t && s == .WRITE, "pending output short of 30 s is fine");
    t, s = is_timed_out(*c, 1000 + 30000);
    assert(t && s == .WRITE, "a stalled write times out at 30 s");

    // The tail drains at t=20000: idle is measured from that progress, not from the request.
    c.pending.count = 0;
    c.last_activity_ms = 20000;
    t, s = is_timed_out(*c, 20000 + 59999);
    assert(!t && s == .IDLE, "idle after a drain counts from the drain");
    t, s = is_timed_out(*c, 20000 + 60000);
    assert(t && s == .IDLE, "then times out at 60 s");
    print("  PASS: test_is_timed_out_write_then_idle\n");
}

test_check_timeouts_closes_idle_silently :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);
    c.last_activity_ms = 0;

    closed := check_timeouts(*w, 59999);
    assert(closed == 0 && c.state == .ACTIVE, "not yet");
    closed = check_timeouts(*w, 60000);
    assert(closed == 1 && c.state == .FREE, "idle connection reaped, got closed=% state=%", closed, c.state);

    got: [..] u8;
    defer array_free(got);
    n := drain_peer(peer, *got);
    assert(n == 0, "an idle timeout sends nothing, got '%'", as_string(got));
    print("  PASS: test_check_timeouts_closes_idle_silently\n");
}

test_check_timeouts_sends_408_for_a_slow_header :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "GET / HTTP/1.1\r\nHost: x\r\n");   // no terminator: headers incomplete
    handle_client(*w, c, EPOLLIN);
    assert(c.state == .ACTIVE && c.bytes_used > 0 && c.request_start_ms > 0, "setup: request in progress");
    c.request_start_ms = 0;   // pretend it started at the epoch

    closed := check_timeouts(*w, 10000);
    assert(closed == 1 && c.state == .FREE, "slow header reaped at 10 s, got closed=%", closed);
    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(starts_with(as_string(got), "HTTP/1.1 408 "), "a header timeout gets 408, got '%'", as_string(got));
    print("  PASS: test_check_timeouts_sends_408_for_a_slow_header\n");
}

test_check_timeouts_skips_free_slots_and_listener :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    w.listen_conn = get_connection(*w.pool);   // sentinel, never timed
    w.listen_conn.last_activity_ms = 0;
    closed := check_timeouts(*w, 1000000);
    assert(closed == 0, "free slots and the listen sentinel are never reaped, got %", closed);
    free_connection(*w.pool, w.listen_conn);
    w.listen_conn = null;
    print("  PASS: test_check_timeouts_skips_free_slots_and_listener\n");
}
```

Register in `main`:

```jai
    print("\nTimeouts:\n");
    test_timeout_state_classification();
    test_is_timed_out_uses_the_right_clock();
    test_is_timed_out_write_then_idle();
    test_check_timeouts_closes_idle_silently();
    test_check_timeouts_sends_408_for_a_slow_header();
    test_check_timeouts_skips_free_slots_and_listener();
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile error, `Undeclared identifier 'timeout_state'`.

- [ ] **Step 3: Implement in `server.jai`** (above `#scope_file`, after `now_ms`)

```jai
// -- Timeouts --
//
// A connection is bounded by one timeout at a time, chosen by what it is waiting for. A request
// that has fully arrived has no deadline: the handler runs synchronously and request_start_ms is
// cleared before dispatch. Sweeps run once a second from worker_run when any timeout is enabled.

TIMEOUTS_ENABLED :: IDLE_TIMEOUT_MS > 0 || HEADER_TIMEOUT_MS > 0 || BODY_TIMEOUT_MS > 0 || WRITE_TIMEOUT_MS > 0;

Timeout_State :: enum u8 #specified {
    NONE   :: 0;
    IDLE   :: 1;   // between requests
    HEADER :: 2;   // request begun, headers incomplete
    BODY   :: 3;   // headers complete, body incomplete
    WRITE  :: 4;   // response tail pending
}

timeout_state :: (c: *Connection) -> Timeout_State {
    if c.pending.count > 0        return .WRITE;
    if c.bytes_used == 0          return .IDLE;
    if c.parse_state == .BODY     return .BODY;
    if c.parse_state == .COMPLETE return .NONE;   // never observed by the sweep; defensive
    return .HEADER;
}

is_timed_out :: (c: *Connection, now: s64) -> (timed_out: bool, state: Timeout_State) {
    state := timeout_state(c);
    limit: s64 = 0;
    since: s64 = 0;
    if state == {
        case .IDLE;   limit = IDLE_TIMEOUT_MS;   since = c.last_activity_ms;
        case .WRITE;  limit = WRITE_TIMEOUT_MS;  since = c.last_activity_ms;
        case .HEADER; limit = HEADER_TIMEOUT_MS; since = c.request_start_ms;
        case .BODY;   limit = BODY_TIMEOUT_MS;   since = c.request_start_ms;
        case;         return false, state;
    }
    if limit <= 0  return false, state;
    return now - since >= limit, state;
}

// Close every active connection whose timeout has passed. Returns how many were closed.
check_timeouts :: (w: *Worker, now: s64) -> s32 {
    closed: s32 = 0;
    for * w.pool.connections {
        c := it;
        if c.state != .ACTIVE || c == w.listen_conn  continue;
        timed_out, state := is_timed_out(c, now);
        if !timed_out  continue;
        Basic.log("fd %: % timeout; closing", c.fd, state);
        if state == .HEADER || state == .BODY  send_canned(c.fd, 408);
        close_connection(w, c);
        closed += 1;
    }
    return closed;
}
```

Change `worker_run`:

```jai
worker_run :: (w: *Worker) {
    last_sweep := now_ms();
    wait_ms: s32 = ifx TIMEOUTS_ENABLED then cast(s32) 1000 else cast(s32) -1;
    while w.running {
        nfds := epoll_process_events(*w.engine, timeout_ms = wait_ms);
        if nfds < 0 {
            err := errno();
            if err == EINTR continue;
            Basic.log_error("Worker %: epoll_wait failed: %", w.id, err);
            continue;
        }

        for i: 0..nfds-1 {
            ev := *w.engine.events[i];
            c, event_instance := decode_connection_ptr(ev.data.ptr);

            // Stale event check
            if event_instance != c.instance continue;

            if c == w.listen_conn {
                accept_connections(w);
            } else {
                handle_client(w, c, ev.events);
            }
        }
        Basic.reset_temporary_storage();

        #if TIMEOUTS_ENABLED {
            now := now_ms();
            if now - last_sweep >= 1000 {
                check_timeouts(w, now);
                last_sweep = now;
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: the six timeout tests `PASS`; all suites green.

- [ ] **Step 5: Manual check that an idle keep-alive is reaped**

The default idle timeout is 60 s. Verify it once end to end with bash's `/dev/tcp`, no extra tools needed:

```bash
./build_debug/hello_world & sleep 1
( exec 3<>/dev/tcp/127.0.0.1/9090; printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' >&3; head -c 200 <&3; echo; echo "--- holding idle 61s"; sleep 61; printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' >&3 || echo "write failed (closed, as expected)"; head -c 200 <&3; exec 3>&- )
kill %1
```
Expected: the first request answers; after 61 s the server log shows `fd N: IDLE timeout; closing` and the second request gets nothing.

- [ ] **Step 6: Commit**

```bash
git add modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: idle/header/body/write timeouts swept once per second, 408 for slow requests"
```

---

### Task 7: Cached Date header and the overlap-safe buffer shift

**Files:**
- Modify: `modules/http_server/http.jai` (`format_http_date`, `reset_for_next_request`)
- Modify: `modules/http_server/server.jai` (`Worker` fields, `refresh_date`, call in `worker_run`)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Produces: `format_http_date :: (ct: Basic.Calendar_Time, out: *[29] u8) -> string`; `refresh_date :: (w: *Worker)`; `Worker.date_buf: [29] u8`, `Worker.date_second: s64`.

- [ ] **Step 1: Write the failing tests**

```jai
// -- Date header and buffer shift (Task 7) --

test_format_http_date :: () {
    ct: Calendar_Time;
    ct.year = 1994;
    ct.month_starting_at_0 = 10;        // November
    ct.day_of_month_starting_at_0 = 5;  // the 6th
    ct.day_of_week_starting_at_0 = 0;   // Sunday
    ct.hour = 8;
    ct.minute = 49;
    ct.second = 37;
    buf: [29] u8;
    s := format_http_date(ct, *buf);
    assert(string_equals(s, "Sun, 06 Nov 1994 08:49:37 GMT"), "RFC 9110 IMF-fixdate, got '%'", s);

    ct.year = 2026; ct.month_starting_at_0 = 0; ct.day_of_month_starting_at_0 = 0;
    ct.day_of_week_starting_at_0 = 4; ct.hour = 0; ct.minute = 0; ct.second = 0;
    s = format_http_date(ct, *buf);
    assert(string_equals(s, "Thu, 01 Jan 2026 00:00:00 GMT"), "zero padding, got '%'", s);
    print("  PASS: test_format_http_date\n");
}

test_refresh_date_caches_per_second :: () {
    w: Worker;
    refresh_date(*w);
    assert(w.date.count == 29, "IMF-fixdate is 29 bytes, got % ('%')", w.date.count, w.date);
    assert(w.date[25] == #char " " && w.date[26] == #char "G" && w.date[28] == #char "T", "ends with GMT, got '%'", w.date);
    first_second := w.date_second;
    first_ptr    := w.date.data;
    refresh_date(*w);
    assert(w.date.data == first_ptr, "the cache is a view into the worker's own buffer");
    assert(w.date_second == first_second || w.date_second == first_second + 1, "at most one tick between two calls");
    print("  PASS: test_refresh_date_caches_per_second\n");
}

test_reset_shift_overlapping_and_disjoint :: () {
    // Overlapping: 100 leftover bytes starting at offset 10 (destination overlaps source).
    c: Connection;
    for i: 0..199  c.buf[i] = cast(u8) i;
    c.bytes_used = 110;
    c.parse_offset = 10;
    reset_for_next_request(*c);
    assert(c.bytes_used == 100 && c.parse_offset == 0, "100 bytes remain at the front");
    for i: 0..99  assert(c.buf[i] == cast(u8) (i + 10), "overlapping shift preserved byte %", i);

    // Disjoint: 5 leftover bytes starting at offset 100.
    c2: Connection;
    for i: 0..199  c2.buf[i] = cast(u8) i;
    c2.bytes_used = 105;
    c2.parse_offset = 100;
    reset_for_next_request(*c2);
    assert(c2.bytes_used == 5, "5 bytes remain");
    for i: 0..4  assert(c2.buf[i] == cast(u8) (i + 100), "disjoint shift preserved byte %", i);
    assert(c2.request_start_ms > 0, "leftover bytes start the next request's clock");

    c3: Connection;
    c3.bytes_used = 50;
    c3.parse_offset = 50;
    reset_for_next_request(*c3);
    assert(c3.bytes_used == 0 && c3.request_start_ms == 0, "nothing left: idle");
    print("  PASS: test_reset_shift_overlapping_and_disjoint\n");
}
```

Register in `main`:

```jai
    print("\nDate header and buffer shift:\n");
    test_format_http_date();
    test_refresh_date_caches_per_second();
    test_reset_shift_overlapping_and_disjoint();
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile error, `Undeclared identifier 'format_http_date'`.

- [ ] **Step 3: `format_http_date` in `http.jai`** (public section)

```jai
HTTP_DAY_NAMES   :: string.["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
HTTP_MONTH_NAMES :: string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// RFC 9110 §5.6.7 IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT": always 29 bytes, written
// into `out`; the returned string is a view into it.
format_http_date :: (ct: Basic.Calendar_Time, out: *[29] u8) -> string {
    two_digits :: (p: *u8, v: s64) {
        p[0] = cast(u8) (#char "0" + v / 10);
        p[1] = cast(u8) (#char "0" + v % 10);
    }
    b := cast(*u8) out;
    memcpy(b, HTTP_DAY_NAMES[cast(s64) ct.day_of_week_starting_at_0].data, 3);
    b[3] = #char ",";
    b[4] = #char " ";
    two_digits(b + 5, cast(s64) ct.day_of_month_starting_at_0 + 1);
    b[7] = #char " ";
    memcpy(b + 8, HTTP_MONTH_NAMES[cast(s64) ct.month_starting_at_0].data, 3);
    b[11] = #char " ";
    year := cast(s64) ct.year;
    two_digits(b + 12, year / 100);
    two_digits(b + 14, year % 100);
    b[16] = #char " ";
    two_digits(b + 17, cast(s64) ct.hour);
    b[19] = #char ":";
    two_digits(b + 20, cast(s64) ct.minute);
    b[22] = #char ":";
    two_digits(b + 23, cast(s64) ct.second);
    memcpy(b + 25, " GMT".data, 4);
    s: string;
    s.data  = b;
    s.count = 29;
    return s;
}
```

Rewrite the shift in `reset_for_next_request`:

```jai
reset_for_next_request :: (c: *Connection) {
    remaining := c.bytes_used - c.parse_offset;
    if remaining > 0 && c.parse_offset > 0 {
        if c.parse_offset >= remaining {
            // Source and destination do not overlap: a plain memcpy is correct (Jai's memcpy is
            // the LLVM intrinsic, undefined on overlap, and Basic has no memmove).
            memcpy(c.buf.data, c.buf.data + c.parse_offset, remaining);
        } else {
            // Overlapping, destination below source: a forward byte copy is safe.
            for i: 0..remaining-1 {
                c.buf[i] = c.buf[c.parse_offset + i];
            }
        }
    }
    c.bytes_used = remaining;
    c.parse_offset = 0;
    c.parse_state = .REQUEST_LINE;
    c.parse_error = .NONE;
    c.req.header_count = 0;
    c.req.keep_alive = false;
    c.req.content_length = 0;
    c.request_start_ms = ifx remaining > 0 then now_ms() else 0;
}
```

- [ ] **Step 4: The worker cache in `server.jai`**

Add to `Worker` (replacing the `date: string;` line from Task 4):

```jai
    date:         string;      // cached IMF-fixdate for this second; a view into date_buf
    date_buf:     [29] u8;
    date_second:  s64 = -1;
```

Add above `#scope_file`:

```jai
// Refresh the cached Date value when the wall-clock second has changed. Called once per epoll
// batch; a batch lasts microseconds, so a response is never more than a batch stale.
refresh_date :: (w: *Worker) {
    now := Basic.current_time_consensus();
    sec, ok := Basic.to_seconds(now);
    if !ok  return;                  // keep the previous value; not worth a per-batch error
    if sec == w.date_second  return;
    w.date_second = sec;
    w.date = format_http_date(Basic.to_calendar(now, .UTC), *w.date_buf);
}
```

In `worker_run`, call `refresh_date(w);` right after the `nfds < 0` check, before the event loop.

- [ ] **Step 5: Run the tests**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: the three new tests `PASS`; `test_reset_for_next_request` still passes; all suites green.

- [ ] **Step 6: Smoke the header**

```bash
~/jai/jai/bin/jai-linux first.jai - hello_world && ./build_debug/hello_world & sleep 1
curl -s -i http://localhost:9090/ | grep -E '^Date:'
kill %1
```
Expected: one `Date: <weekday>, DD Mon YYYY HH:MM:SS GMT` line matching the current UTC time.

- [ ] **Step 7: Commit**

```bash
git add modules/http_server/http.jai modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: per-worker cached Date header, overlap-safe pipelined buffer shift"
```

---

### Task 8: Slow-client example, verification grid, docs

**Files:**
- Create: `examples/large_body.jai`
- Modify: `CLAUDE.md` (Project Overview status line, http_server module bullets, Key Patterns, Remaining Library Gaps)

- [ ] **Step 1: Add the example**

```jai
// A 1 MB response body on every request, for exercising the pending-output path against a real
// TCP client: `curl --limit-rate 50k` makes the socket fill, so the tail queues on EPOLLOUT.
#import "http_server"()(Handler_Data = http_router.Router);
http_router :: #import "http_router";

large_body: string;

large_handler :: (request: *Request, response: *Response) {
    response.status_code  = 200;
    response.content_type = "application/octet-stream";
    response.body         = large_body;
}

main :: () {
    large_body = alloc_string(1048576);
    memset(large_body.data, #char "x", large_body.count);

    router: http_router.Router;
    http_router.get(*router, "/", large_handler);

    server: Server;
    ok := init_server(*server);
    if !ok {
        print("Failed to initialize server\n");
        return;
    }
    defer destroy_server(*server);

    http_router.serve(*server, *router);

    ok = server_listen(*server, "0.0.0.0", 9090);
    if !ok {
        print("Failed to listen\n");
        return;
    }

    server_run(*server);
}

#import "Basic";
```

- [ ] **Step 2: Build everything and run every suite, debug and release**

```bash
~/jai/jai/bin/jai-linux first.jai -
~/jai/jai/bin/jai-linux first.jai - run-tests
~/jai/jai/bin/jai-linux first.jai - run-tests -release
```
Expected: five examples in `build_debug/`; every suite prints `All tests passed.` in both modes.

- [ ] **Step 3: Manual protocol checks against `hello_world`**

```bash
~/jai/jai/bin/jai-linux first.jai - hello_world && ./build_debug/hello_world & sleep 1
echo "--- HEAD: 200, Content-Length: 13, no body";           curl -s -I http://localhost:9090/
echo "--- 405 with Allow";                                   curl -s -i -X POST http://localhost:9090/ | head -4
echo "--- HTTP/1.0 closes";                                  curl -s -i --http1.0 http://localhost:9090/ | grep -i '^connection'
echo "--- HTTP/1.0 keep-alive is explicit";                  curl -s -i --http1.0 -H 'Connection: keep-alive' http://localhost:9090/ | grep -i '^connection'
echo "--- 1.1 keep-alive says nothing";                      curl -s -i http://localhost:9090/ | grep -ci '^connection' || true
echo "--- oversized header: 431";                            curl -s -i -H "X-Pad: $(head -c 5000 /dev/zero | tr '\0' x)" http://localhost:9090/ | head -1
echo "--- malformed: 400";                                   ( exec 3<>/dev/tcp/127.0.0.1/9090; printf 'GARBAGE\r\n\r\n' >&3; head -1 <&3; exec 3>&- )
kill %1
```
Expected, in order: `HTTP/1.1 200 OK` with `Content-Length: 13` and nothing after the headers; `HTTP/1.1 405` and `Allow: GET, HEAD`; `Connection: close`; `Connection: keep-alive`; `0`; `HTTP/1.1 431`; `HTTP/1.1 400`.

- [ ] **Step 4: Slow client against the 1 MB body**

```bash
~/jai/jai/bin/jai-linux first.jai - large_body && ./build_debug/large_body & sleep 1
curl -s --limit-rate 200k -o /dev/null -w 'downloaded=%{size_download} http=%{http_code} time=%{time_total}s\n' http://localhost:9090/
curl -s --limit-rate 200k -o /dev/null -w 'downloaded=%{size_download} http=%{http_code}\n' http://localhost:9090/
kill %1
```
Expected: `downloaded=1048576 http=200` twice, around 5 s each. Before this plan the first number was short and the server logged nothing. Also confirm the server printed no `log_error` lines.

- [ ] **Step 5: Benchmark grid and compare to the Task 1 baseline**

```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
./build_release/hello_world &
sleep 1
for cfg in "1 10" "4 100" "8 500" "16 1000" "32 2000"; do set -- $cfg; wrk -t$1 -c$2 -d10s http://localhost:9090/ | grep -E 'Requests/sec|Socket errors|Non-2xx'; done
kill %1
```
Expected: within noise of the Task 1 baseline at every point, zero socket errors, zero non-2xx. The response now carries a `Date` header and a shorter header without `Connection`, so bytes per response change by a few bytes either way. If t16 or t32 drop more than ~5%, profile `build_response_header` first: restoring a `sprint` fast path for `header_count == 0` is the known cheap fix. Record the five numbers under **Appendix: wrk after**.

- [ ] **Step 6: Update `CLAUDE.md`**

Make these edits (keep the existing voice):

1. Project Overview "Current status": append a sentence: `The core's write path is now correct under a full socket buffer (SENT/PENDING/ERROR writer, permanent edge-triggered EPOLLOUT, heap-pinned per-connection pending tail capped by MAX_PENDING_BYTES, dispatch paused while output is queued), requests are answered before hangups are honored, idle/header/body/write timeouts are swept once per second, and HEAD/405 Allow/204-304/400-413-431 semantics follow RFC 9110. All socket writes use MSG_NOSIGNAL. See docs/plans/2026-10-03-fib-lifts-{design,implementation}.md.` Update the test counts to the new totals printed by `run-tests`.
2. Architecture → http_server `module.jai` bullet: list the five new group-1 params with defaults.
3. Architecture → `server.jai` bullet: describe the flush → read-and-dispatch → hangup order, the stalled-read flag, the one-second timeout sweep and the cached Date.
4. Architecture → `http.jai` bullet: `Write_Result`, `flush_pending`, canned replies, `format_http_date`.
5. Architecture → `http_router` `router.jai`/`trie.jai`: GET answers HEAD; `tree_match` returns `allow`.
6. Key Patterns: add `**Permanent EPOLLOUT:** registered once with EPOLLET; an OUT with nothing queued is ignored; never epoll_ctl MOD` and `**Pending tail lives on the heap:** Connection.pending's allocator is pinned in init_pool because the request Pool and temp storage are reset underneath a stalled response`.
7. Remaining Library Gaps: note under "Static file serving handler" that its prerequisite (correct partial-write handling) is done.
8. Add a line to the Benchmark History with the Task 1 and Task 8 numbers, labeled `fib lifts (2026-10)`.

- [ ] **Step 7: Commit and open the PR**

```bash
git add examples/large_body.jai CLAUDE.md docs/plans/2026-10-03-fib-lifts-implementation.md
git commit -m "fib lifts: large_body example, docs, benchmark record"
git push -u origin fib-lifts
gh pr create --title "Lift fib's correctness techniques: send queue, event ordering, timeouts, HTTP semantics" --body "$(cat <<'EOF'
Implements docs/plans/2026-10-03-fib-lifts-design.md.

- Writer reports SENT/PENDING/ERROR; unsent tails queue on a heap-pinned per-connection buffer (MAX_PENDING_BYTES, 1 MB) drained by a permanent edge-triggered EPOLLOUT; dispatch pauses while output is pending.
- handle_client: flush, then read-and-dispatch, then hangups, so a request arriving with the peer's FIN is answered.
- Idle / header / body / write timeouts (module params, 60/10/30/30 s), swept once per second; 408 for slow requests.
- GET routes answer HEAD; 405 carries Allow; 204/304 are bodiless; 400/413/431 canned replies.
- All socket writes use MSG_NOSIGNAL (closes a latent SIGPIPE kill).
- Cached Date header, Connection header only where HTTP/1.1 needs it.

Tests: see run-tests totals. Benchmarks: see CLAUDE.md Benchmark History (no regression).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Appendix: wrk baseline (Task 1, before any change)

2026-10-03, Threadripper 3970X (64 logical), governor `performance`, mitigations ON (kernel default), Jai beta 0.2.030, release `hello_world`, `wrk -d10s`. Zero socket errors and zero non-2xx at every point.

| wrk         | Requests/sec | Avg latency |
|-------------|-------------:|------------:|
| t1 / c10    |      131,893 |     46.96us |
| t4 / c100   |      384,035 |    150.30us |
| t8 / c500   |      695,974 |    415.26us |
| t16 / c1000 |    1,360,956 |    620.61us |
| t32 / c2000 |    1,342,797 |      1.44ms |

Matches the 2026-06-22 mitigations-ON ceiling (~1.3M at t16/t32).

## Appendix: wrk after (Task 8)

_(fill in the same five lines)_
