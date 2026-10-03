# Chunked request bodies and slow-client defenses — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode chunked request bodies strictly (RFC 9112), and bound what slow clients can hold: time on a response tail (a minimum drain rate), memory across all tails (a per-worker budget), and a slot that never receives a byte (a first-request deadline).

**Architecture:** The chunked decoder works in place in the connection's read buffer: a write cursor trails the read cursor, chunk data moves down, framing is skipped, and the finished body is one contiguous view. Framing rules live in `finish_headers`. The slow-client defenses hang off the existing once-a-second sweep: a queued tail gets a size-scaled deadline, every tail is charged to its worker's pool and refunded in `release_pending`, and a fresh connection is timed from accept.

**Tech Stack:** Jai beta 0.2.030 at `~/jai/jai/`; standard modules only (Basic, Pool, POSIX, Linux, Socket, Thread). Build and test only through `first.jai`.

**Spec:** `docs/plans/2026-10-03-chunked-and-slow-clients-design.md`. Read it first; this plan argues from it.

## Global Constraints

- **Load the `jai-language` skill before writing or editing any Jai** (project CLAUDE.md; mandatory for every task and every subagent).
- Build and test only via the metaprogram: `~/jai/jai/bin/jai-linux first.jai - run-tests` (all suites), `~/jai/jai/bin/jai-linux first.jai - run-tests -release`, `~/jai/jai/bin/jai-linux first.jai -` (all examples). Never call the compiler on a module file.
- `Handler :: #type (request: *Request, response: *Response)`, `Request` and `Response` keep their fields; `examples/*.jai` must compile without edits.
- New parameters go in `http_server`'s **second** (program-wide) parameter list, like every existing one.
- Module parameters are invisible to importers, so tests assert the documented defaults as literals: `MIN_SEND_RATE = 16384`, `MAX_PENDING_PER_WORKER = 67108864`, `MAX_PENDING_BYTES = 1048576`, `READ_BUFFER_SIZE = 4096`, `HEADER_TIMEOUT_MS = 10000`, `BODY_TIMEOUT_MS = 30000`, `WRITE_TIMEOUT_MS = 30000`.
- `first.jai` sets `arithmetic_overflow_check = .FATAL` in every build: an overflow kills the server. Bound every client-supplied number before computing it (chunk sizes: at most 15 significant hex digits).
- Jai's `memcpy` is undefined on overlapping regions and Basic has no `memmove`: moves inside the read buffer go through `move_down` (Task 1).
- Jai precedence trap: `&` binds looser than `==`. Write bit tests as `(events & FLAG) != 0`.
- Failure policy (spec §6): framing violations get a canned 400/501/413 through `refuse_and_close`; slow-client closes are `Basic.log` (info), one line per close; tail refusals are counted and reported by `worker_sweep` as one `Basic.log_error` line per worker per second.
- Tests: sequential `test_*` procs printing `  PASS: name`, registered in `main`; no sleeping; socket conditions forced with small `SO_SNDBUF` socketpairs, as the existing suite does.
- Work on branch `chunked-slow-clients`. Each task ends green (`run-tests` passes) and with one commit ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Deviations from the spec, decided while planning:**
1. The budget charge is recorded in a `pending_charge` field and refunded from it, rather than refunding `pending.allocated`. Tests append to `pending` directly (never charged); refunding `allocated` there would drive the total negative.
2. `standalone_connection` (tests) points at a shared accounting pool, `standalone_pool`, rather than a real one-slot pool: the writer tests `free()` standalone connections one by one, which an interior pointer into a pool array cannot survive.
3. `Tail_Refusal`, `tail_refusal` and `reserve_tail` live in `connection.jai` beside `release_pending`, so charge and refund sit together; the spec's file table put them in `http.jai`.

## Review Focus

Inputs the spec implies but no task's tests would otherwise exercise, most likely to bite first. Each line is pinned by a test in the owning task.

1. **A chunked request that fills `READ_BUFFER_SIZE` exactly** must be served, and one byte more must be 413: off-by-one territory between the decoder's early size check and the buffer-full path. → Task 2 `test_chunked_buffer_edge`.
2. **Framing fields in trailers** (`Content-Length`, `Transfer-Encoding`) must change nothing: the body stays as decoded and a pipelined request behind it parses intact. → Task 2 `test_chunked_trailers_cannot_reframe`.
3. **A chunked body followed by a partial next request** in the same read, completed by a later read, must serve both. → Task 2 `test_chunked_then_partial_next_request`.
4. **A chunked request pipelined behind a stalled response** must decode correctly after the drain (the decoder runs late, on bytes that waited). → Task 2 `test_chunked_behind_stalled_response`.
5. **A canned refusal queued under backpressure** must get a drain deadline and be charged to the budget like a response tail. → Task 3 `test_canned_tail_gets_a_drain_deadline`, Task 4 `test_pending_budget_accounting_balances`.

---

## File Structure

| File                                 | Responsibility after this plan                                                                     |
|--------------------------------------|----------------------------------------------------------------------------------------------------|
| `modules/http_server/module.jai`     | parameters (two new: `MIN_SEND_RATE`, `MAX_PENDING_PER_WORKER`)                                    |
| `modules/http_server/http.jai`       | parser incl. `parse_chunked` and the TE rules, `reset_parse`, `move_down`, writer (reserves tails) |
| `modules/http_server/connection.jai` | `Connection` (chunk and budget fields), pool accounting: `reserve_tail`, `tail_refusal`, refunds   |
| `modules/http_server/server.jai`     | timeouts (`NEW`, drain deadline), refusal report, unconditional sweep, CHUNKED 413                 |
| `modules/http_server/tests/test.jai` | the new tests; `standalone_pool`; R5 test replaced                                                 |
| `README.md`, `CLAUDE.md`             | parameters, status, open items closed, benchmark entry                                             |

---

### Task 1: In-place chunked decoder

The decoder alone, driven directly in the state `finish_headers` will leave a chunked request in (Task 2 wires it in).

**Files:**
- Modify: `modules/http_server/http.jai` (`Parse_State`, new `Chunk_Phase`, new `parse_chunked`, `reset_for_next_request` shift, `is_token`, new `#scope_file` helpers)
- Modify: `modules/http_server/connection.jai` (`Connection` fields)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Produces: `Parse_State.CHUNKED :: 5`; `Chunk_Phase :: enum u8 #specified { SIZE :: 0; DATA :: 1; DATA_CRLF :: 2; TRAILERS :: 3; }`; `Connection.chunk_phase: Chunk_Phase`, `chunk_remaining: s64`, `body_start: s64`, `body_end: s64`; `parse_chunked :: (c: *Connection) -> Parse_Result` (exported); `move_down :: (buf: *u8, dst: s64, src: s64, count: s64)` (`#scope_file`).
- Test helpers produced: `CHUNK_PREFIX`, `decode_chunked_body`, `expect_decoded`, `expect_refused`, `with_ctl`.

- [ ] **Step 1: Write the failing tests**

Add after the "Request body" tests (before `test_reset_for_next_request`):

```jai
// -- Chunked bodies --

CHUNK_PREFIX :: "[the request head]";   // stands in for the header bytes in front of the body

// Set c up as finish_headers leaves a chunked request (the body starts right after CHUNK_PREFIX),
// then feed `raw` to parse_chunked, whole (step 0) or `step` bytes per call. Returns the first
// result other than INCOMPLETE, or INCOMPLETE once everything is fed.
decode_chunked_body :: (c: *Connection, raw: string, step: s64 = 0) -> Parse_Result {
    memcpy(c.buf.data, CHUNK_PREFIX.data, CHUNK_PREFIX.count);
    c.bytes_used   = CHUNK_PREFIX.count;
    c.parse_offset = CHUNK_PREFIX.count;
    c.parse_state  = .CHUNKED;
    c.chunk_phase  = .SIZE;
    c.body_start   = CHUNK_PREFIX.count;
    c.body_end     = CHUNK_PREFIX.count;
    if step <= 0  step = raw.count;
    fed := 0;
    r := Parse_Result.INCOMPLETE;
    while fed < raw.count {
        n := ifx raw.count - fed < step then raw.count - fed else step;
        memcpy(c.buf.data + c.bytes_used, raw.data + fed, n);
        c.bytes_used += n;
        fed += n;
        r = parse_chunked(c);
        if r != .INCOMPLETE  return r;
    }
    return r;
}

expect_decoded :: (raw: string, want: string, step: s64) {
    c := New(Connection);
    defer free(c);
    r := decode_chunked_body(c, raw, step);
    assert(r == .COMPLETE, "'%' (step %): expected COMPLETE, got % (%)", raw, step, r, c.parse_error);
    assert(string_equals(c.req.body, want), "'%' (step %): body '%', want '%'", raw, step, c.req.body, want);
    assert(c.req.content_length == want.count, "'%' (step %): content_length %, want %", raw, step, c.req.content_length, want.count);
    assert(c.parse_offset == CHUNK_PREFIX.count + raw.count, "'%' (step %): the whole message and no more is consumed: offset % of %", raw, step, c.parse_offset, CHUNK_PREFIX.count + raw.count);
    assert(c.req.header_count == 0, "'%': trailers never enter req.headers", raw);
    head: string;
    head.data  = c.buf.data;
    head.count = CHUNK_PREFIX.count;
    assert(string_equals(head, CHUNK_PREFIX), "'%': decoding wrote below body_start: '%'", raw, head);
}

expect_refused :: (raw: string, want: Parse_Error, step: s64) {
    c := New(Connection);
    defer free(c);
    r := decode_chunked_body(c, raw, step);
    assert(r == .ERROR && c.parse_error == want, "'%' (step %): expected ERROR %, got % (%)", raw, step, want, r, c.parse_error);
}

// `s` with every '~' replaced by the control byte 0x01 (there is no portable escape for it).
with_ctl :: (s: string) -> string {
    r := copy_string(s);
    for i: 0..r.count-1  if r[i] == #char "~"  r[i] = 0x01;
    return r;
}

Chunked_Case :: struct { raw: string; want: string; }

test_chunked_decodes_in_place :: () {
    cases := Chunked_Case.[
        .{"5\r\nhello\r\n0\r\n\r\n", "hello"},
        .{"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", "hello world"},
        .{"0005\r\nhello\r\n000\r\n\r\n", "hello"},                           // leading zeros, last-chunk "000"
        .{"a\r\n0123456789\r\nA\r\nabcdefghij\r\n0\r\n\r\n", "0123456789abcdefghij"},   // lower and upper hex
        .{"5;name=value\r\nhello\r\n0;x\r\n\r\n", "hello"},                   // token extensions, ignored
        .{"5 ; q=\"a \\\"b\\\" c\"\r\nhello\r\n0\r\n\r\n", "hello"},          // BWS, quoted-string with quoted-pairs
        .{"5\r\nhello\r\n0\r\nExpires: never\r\nX-Sum:\tabc \r\n\r\n", "hello"},   // trailers, discarded
        .{"0\r\n\r\n", ""},                                                   // empty body
    ];
    for tc: cases {
        expect_decoded(tc.raw, tc.want, 0);
        expect_decoded(tc.raw, tc.want, 1);   // one byte per call: resumable at every split point
    }
    print("  PASS: test_chunked_decodes_in_place\n");
}

Chunk_Refusal :: struct { raw: string; want: Parse_Error; }

test_chunked_grammar_refused :: () {
    cases := Chunk_Refusal.[
        .{"0x5\r\nhello\r\n0\r\n\r\n", .MALFORMED},            // no 0x prefix
        .{"+5\r\nhello\r\n0\r\n\r\n", .MALFORMED},             // no sign
        .{"-5\r\nhello\r\n0\r\n\r\n", .MALFORMED},
        .{" 5\r\nhello\r\n0\r\n\r\n", .MALFORMED},             // no leading whitespace
        .{"5 \r\nhello\r\n0\r\n\r\n", .MALFORMED},             // trailing whitespace without ';'
        .{"5\nhello\r\n0\r\n\r\n", .MALFORMED},                // bare LF ends no line
        .{"5\r\nhello\n0\r\n\r\n", .MALFORMED},                // LF-only after the data
        .{"5\r\nhelloX\r\n0\r\n\r\n", .MALFORMED},             // data longer than its size
        .{"5\r\nhell\r\n0\r\n\r\n", .MALFORMED},               // data shorter than its size
        .{"5;a@b\r\nhello\r\n0\r\n\r\n", .MALFORMED},          // '@' is not a token byte
        .{"5;\r\nhello\r\n0\r\n\r\n", .MALFORMED},             // an extension needs a name
        .{"5;a=\"open\r\nhello\r\n0\r\n\r\n", .MALFORMED},     // unterminated quoted-string
        .{"5;a= \r\nhello\r\n0\r\n\r\n", .MALFORMED},          // '=' needs a value
        .{"5\r\nhello\r\n0\r\nBad Name: x\r\n\r\n", .MALFORMED},   // trailer name with a space
        .{"5\r\nhello\r\n0\r\nX-A: 1\r\n folded\r\n\r\n", .MALFORMED},   // obs-fold trailer
        .{"5\r\nhello\r\n0\r\nNoColon\r\n\r\n", .MALFORMED},
    ];
    for tc: cases {
        expect_refused(tc.raw, tc.want, 0);
        expect_refused(tc.raw, tc.want, 1);
    }
    ctl := with_ctl("5\r\nhello\r\n0\r\nX-A: a~b\r\n\r\n");   // a control byte in a trailer value
    defer free(ctl);
    expect_refused(ctl, .MALFORMED, 0);
    print("  PASS: test_chunked_grammar_refused\n");
}

test_chunk_size_limits :: () {
    // A size larger than the rest of the read buffer is refused as soon as its line is complete.
    expect_refused("1000\r\n", .BODY_TOO_LARGE, 0);                // 4096 bytes cannot fit after the head
    expect_refused("FFFFFFFFFFFFFFF\r\n", .BODY_TOO_LARGE, 0);     // 15 digits: computed (no overflow), too large
    // Leading zeros carry no magnitude: 19 digits, one significant.
    c := New(Connection);
    defer free(c);
    r := decode_chunked_body(c, "0000000000000000001\r\n");
    assert(r == .INCOMPLETE && c.chunk_phase == .DATA && c.chunk_remaining == 1, "leading zeros are not significant digits; got % in % with % remaining (%)",
        r, c.chunk_phase, c.chunk_remaining, c.parse_error);
    print("  PASS: test_chunk_size_limits\n");
}

// 16 hex digits is the first width that can overflow s64; overflow is FATAL in every build, so a
// broken digit guard would kill the process. Parsed in a forked child, as R2 does.
test_chunk_size_overflow_rejected :: () {
    pid := fork();
    if pid == 0 {
        c := New(Connection);
        r := decode_chunked_body(c, "FFFFFFFFFFFFFFFF\r\n");
        _exit(100 + 10 * cast(s32) r + cast(s32) c.parse_error);   // result and cause in one code
    }
    status: s32;
    waitpid(pid, *status, 0);
    exited := (status & 0x7f) == 0;
    code := (status >> 8) & 0xff;
    what := ifx !exited then "died on a signal" else ifx code == 1 then "PANICKED (arithmetic overflow; a live server dies)"
            else tprint("returned exit code % (100 + 10 * Parse_Result + Parse_Error)", code);
    assert(exited && code == 100 + 10 * cast(s32) Parse_Result.ERROR + cast(s32) Parse_Error.BODY_TOO_LARGE,
        "a 16-hex-digit chunk size must be BODY_TOO_LARGE; the parse %", what);
    print("  PASS: test_chunk_size_overflow_rejected\n");
}
```

Register in `main`, as a new group after "Request body:":

```jai
    print("\nChunked bodies:\n");
    test_chunked_decodes_in_place();
    test_chunked_grammar_refused();
    test_chunk_size_limits();
    test_chunk_size_overflow_rejected();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile errors in the http_server suite: `CHUNKED` is not a member of `Parse_State`, `chunk_phase` is not a member of `Connection`, `parse_chunked` is undeclared.

- [ ] **Step 3: Add the state and the fields**

In `http.jai`, extend `Parse_State` and add `Chunk_Phase` after it:

```jai
Parse_State :: enum u8 #specified {
    REQUEST_LINE :: 0;
    HEADERS      :: 1;
    BODY         :: 2;   // Content-Length body
    COMPLETE     :: 3;
    ERROR        :: 4;
    CHUNKED      :: 5;   // chunked body, decoded in place by parse_chunked
}

// Where parse_chunked is within a chunked body (RFC 9112 §7.1).
Chunk_Phase :: enum u8 #specified {
    SIZE      :: 0;   // expecting a chunk-size line, with optional extensions
    DATA      :: 1;   // moving chunk data down to body_end
    DATA_CRLF :: 2;   // expecting the CRLF that ends a chunk's data
    TRAILERS  :: 3;   // after the last chunk: trailer field lines until an empty line
}
```

In `connection.jai`, add to `Connection` after `req: Request;`:

```jai
    // Chunked body decoding (parse_chunked). The decoded body is buf[body_start .. body_end);
    // body_end trails parse_offset, because decoding only ever removes framing bytes.
    chunk_phase:     Chunk_Phase;
    chunk_remaining: s64;          // bytes of the current chunk's data not yet consumed
    body_start:      s64;
    body_end:        s64;
```

- [ ] **Step 4: Add `move_down` and use it in the buffer shift**

In `http.jai`'s `#scope_file` region (after `make_view`):

```jai
// Copy `count` bytes from buf+src down to buf+dst (dst <= src). Jai's memcpy is the LLVM
// intrinsic, undefined on overlap, and Basic has no memmove: memcpy only when the regions are
// disjoint, otherwise a forward byte copy, which is safe while the destination is below the source.
move_down :: (buf: *u8, dst: s64, src: s64, count: s64) {
    if count <= 0 || dst == src  return;
    if src - dst >= count  memcpy(buf + dst, buf + src, count);
    else                   for i: 0..count-1  buf[dst + i] = buf[src + i];
}
```

Replace the shift at the top of `reset_for_next_request`:

```jai
reset_for_next_request :: (c: *Connection) {
    remaining := c.bytes_used - c.parse_offset;
    if remaining > 0  move_down(c.buf.data, 0, c.parse_offset, remaining);
    c.bytes_used = remaining;
    c.parse_offset = 0;
    c.parse_state = .REQUEST_LINE;
    c.parse_error = .NONE;
    reset_request(*c.req);
    c.request_start_ms = ifx remaining > 0 then now_ms() else 0;   // a pipelined next request is timed from now
}
```

- [ ] **Step 5: Add the grammar helpers**

In the `#scope_file` region, replace `is_token` with a version built on `is_tchar`, and add the rest after `is_field_value`:

```jai
// RFC 9110 §5.6.2: tchar = ALPHA / DIGIT / one of the punctuation below.
is_tchar :: inline (ch: u8) -> bool {
    TCHAR_PUNCTUATION :: "!#$%&'*+-.^_`|~";
    if (ch >= #char "a" && ch <= #char "z") || (ch >= #char "A" && ch <= #char "Z") || (ch >= #char "0" && ch <= #char "9")  return true;
    for p: 0..TCHAR_PUNCTUATION.count-1  if ch == TCHAR_PUNCTUATION[p]  return true;
    return false;
}

// RFC 9110 §5.6.2: token = 1*tchar.
is_token :: (s: string) -> bool {
    if s.count == 0  return false;
    for i: 0..s.count-1  if !is_tchar(s[i])  return false;
    return true;
}
```

```jai
hex_value :: inline (ch: u8) -> s64 {
    if ch >= #char "0" && ch <= #char "9"  return cast(s64) (ch - #char "0");
    if ch >= #char "a" && ch <= #char "f"  return cast(s64) (ch - #char "a") + 10;
    if ch >= #char "A" && ch <= #char "F"  return cast(s64) (ch - #char "A") + 10;
    return -1;
}

// From the opening DQUOTE at s[start], the index just past the closing one, or -1. RFC 9110 §5.6.4:
// qdtext = HTAB / SP / 0x21 / 0x23-0x5B / 0x5D-0x7E / obs-text; quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text ).
skip_quoted_string :: (s: string, start: s64) -> s64 {
    i := start + 1;
    while i < s.count {
        ch := s[i];
        if ch == #char "\""  return i + 1;
        if ch == #char "\\" {
            if i + 1 >= s.count  return -1;
            q := s[i + 1];
            if !(q == #char "\t" || (q >= 0x20 && q != 0x7F))  return -1;
            i += 2;
            continue;
        }
        if !(ch == #char "\t" || (ch >= 0x20 && ch != 0x7F))  return -1;
        i += 1;
    }
    return -1;
}

// chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] ), chunk-ext-val =
// token / quoted-string (RFC 9112 §7.1.1). Empty is valid. Whitespace is only allowed where the
// grammar has BWS, so trailing whitespace with no ';' after it fails.
is_chunk_ext :: (s: string) -> bool {
    i := 0;
    while i < s.count {
        while i < s.count && is_ows(s[i])  i += 1;
        if i == s.count || s[i] != #char ";"  return false;
        i += 1;
        while i < s.count && is_ows(s[i])  i += 1;
        name_start := i;
        while i < s.count && is_tchar(s[i])  i += 1;
        if i == name_start  return false;
        j := i;
        while j < s.count && is_ows(s[j])  j += 1;
        if j < s.count && s[j] == #char "=" {
            i = j + 1;
            while i < s.count && is_ows(s[i])  i += 1;
            if i < s.count && s[i] == #char "\"" {
                i = skip_quoted_string(s, i);
                if i < 0  return false;
            } else {
                value_start := i;
                while i < s.count && is_tchar(s[i])  i += 1;
                if i == value_start  return false;
            }
        }
    }
    return true;
}

// chunk-size [ chunk-ext ], from a chunk-size line without its CRLF (RFC 9112 §7.1). More than 15
// significant hex digits is too large without being computed: 16^15 < 2^63, and arithmetic
// overflow is FATAL in every build.
parse_chunk_size_line :: (line: string) -> (size: s64, error: Parse_Error) {
    digits := 0;
    while digits < line.count && hex_value(line[digits]) >= 0  digits += 1;
    if digits == 0  return 0, .MALFORMED;
    if !is_chunk_ext(make_view(line.data, digits, line.count))  return 0, .MALFORMED;
    first := 0;   // leading zeros are legal and carry no magnitude
    while first < digits - 1 && line[first] == #char "0"  first += 1;
    if digits - first > 15  return 0, .BODY_TOO_LARGE;
    value: s64 = 0;
    for i: first..digits-1  value = value * 16 + hex_value(line[i]);
    return value, .NONE;
}

// A field line without its CRLF: a token name, ':' with no whitespace before it, and a field value
// without control bytes (RFC 9112 §5.1, RFC 9110 §5.5). obs-fold starts with SP or HTAB and fails.
is_field_line :: (line: string) -> bool {
    colon := find_byte(line.data, 0, line.count, #char ":");
    if colon < 0  return false;
    return is_token(make_view(line.data, 0, colon)) && is_field_value(trim_ows(make_view(line.data, colon + 1, line.count)));
}
```

- [ ] **Step 6: Add `parse_chunked`**

In the exported region of `http.jai`, right after `parse_request`:

```jai
// Decode a chunked body in place (RFC 9112 §7.1). Chunk data is moved down to body_end and the
// framing is skipped, so on COMPLETE the body is the contiguous view buf[body_start .. body_end)
// and parse_offset sits just past the message. Resumable: each call continues from chunk_phase.
// Expects the state finish_headers leaves: parse_state CHUNKED, phase SIZE, body_start = body_end
// = parse_offset.
parse_chunked :: (c: *Connection) -> Parse_Result {
    while true {
        if c.chunk_phase == {
          case .SIZE;
            crlf := find_crlf(c.buf.data, c.parse_offset, c.bytes_used);
            if crlf < 0  return .INCOMPLETE;
            size, size_error := parse_chunk_size_line(make_view(c.buf.data, c.parse_offset, crlf));
            if size_error != .NONE  return parse_fail(c, size_error);
            c.parse_offset = crlf + 2;
            if size == 0 { c.chunk_phase = .TRAILERS; continue; }
            // The data and its CRLF must fit in what is left of the read buffer.
            if size > cast(s64) READ_BUFFER_SIZE - c.parse_offset - 2  return parse_fail(c, .BODY_TOO_LARGE);
            c.chunk_remaining = size;
            c.chunk_phase = .DATA;

          case .DATA;
            available := c.bytes_used - c.parse_offset;
            n := ifx available < c.chunk_remaining then available else c.chunk_remaining;
            move_down(c.buf.data, c.body_end, c.parse_offset, n);
            c.body_end        += n;
            c.parse_offset    += n;
            c.chunk_remaining -= n;
            if c.chunk_remaining > 0  return .INCOMPLETE;
            c.chunk_phase = .DATA_CRLF;

          case .DATA_CRLF;
            if c.bytes_used - c.parse_offset < 2  return .INCOMPLETE;
            if c.buf[c.parse_offset] != #char "\r" || c.buf[c.parse_offset + 1] != #char "\n"  return parse_fail(c, .MALFORMED);
            c.parse_offset += 2;
            c.chunk_phase = .SIZE;

          case .TRAILERS;
            crlf := find_crlf(c.buf.data, c.parse_offset, c.bytes_used);
            if crlf < 0  return .INCOMPLETE;
            if crlf == c.parse_offset {
                c.parse_offset       = crlf + 2;
                c.req.body           = make_view(c.buf.data, c.body_start, c.body_end);
                c.req.content_length = c.body_end - c.body_start;
                c.parse_state        = .COMPLETE;
                return .COMPLETE;
            }
            // Validated like a header field, then discarded: a trailer never enters req.headers,
            // where a framing field could change how the message is read.
            if !is_field_line(make_view(c.buf.data, c.parse_offset, crlf))  return parse_fail(c, .MALFORMED);
            c.parse_offset = crlf + 2;
        }
    }
    return .INCOMPLETE;   // unreachable; `while true` alone does not satisfy the return-path check
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: `All tests passed.` for http_server (the four new tests print PASS), and every other suite passes.

- [ ] **Step 8: Commit**

```bash
git add modules/http_server/http.jai modules/http_server/connection.jai modules/http_server/tests/test.jai
git commit -m "http_server: in-place chunked body decoder (parse_chunked)

Decodes RFC 9112 chunked framing inside the read buffer: a write cursor
trails the read cursor, chunk data moves down, framing is skipped. Strict
grammar (CRLF only, extensions and trailers validated and ignored), chunk
sizes bounded to 15 significant hex digits before any arithmetic. Not wired
into parse_request yet. The buffer shift's overlap logic becomes move_down.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Framing rules and wiring

`finish_headers` applies the spec's TE table and chooses the body state; `parse_request` enters `CHUNKED`; resets, the buffer-full status and the timeout state learn about it.

**Files:**
- Modify: `modules/http_server/http.jai` (`parse_request` HEADERS block, `finish_headers`, `determine_keep_alive`, new `transfer_coding_error`, `next_list_member`, `reset_parse`)
- Modify: `modules/http_server/connection.jai` (`get_connection`)
- Modify: `modules/http_server/server.jai` (`timeout_state`, `read_and_dispatch`)
- Test: `modules/http_server/tests/test.jai` (new tests; `test_transfer_encoding_refused` replaced)

**Interfaces:**
- Consumes: `parse_chunked`, `Chunk_Phase`, the chunk fields (Task 1).
- Produces: `finish_headers :: (c: *Connection) -> (error: Parse_Error, next: Parse_State)` (`#scope_file`); `reset_parse :: (c: *Connection)` (exported); `transfer_coding_error :: (req: *Request, has_content_length: bool) -> Parse_Error` and `next_list_member :: (rest: *string) -> string` (`#scope_file`).
- Test helpers produced: `body_handler`, `last_body`, `mixed_handler`, `hex`, `concat`.

- [ ] **Step 1: Write the failing tests**

Add the handler and string helpers next to `ok_handler` / `big_handler`:

```jai
last_body_buf: [4096] u8;
last_body_len: s64;

// Counts the call and records the request body (copied: the view dies with the buffer shift).
body_handler :: (req: *Request, resp: *Response) {
    test_handler_calls += 1;
    last_body_len = req.body.count;
    memcpy(last_body_buf.data, req.body.data, req.body.count);
    resp.status_code = 200;
    resp.body = "ok";
}

last_body :: () -> string {
    s: string;
    s.data  = last_body_buf.data;
    s.count = last_body_len;
    return s;
}

// body_handler plus a large response for /big, so a test can stall the first of two requests.
mixed_handler :: (req: *Request, resp: *Response) {
    body_handler(req, resp);
    if string_equals(req.path, "/big")  resp.body = big_test_body;
}

// Lower-case hex digits of n >= 0 (formatInt is soft-deprecated in beta 0.2.030).
hex :: (n: s64) -> string {
    DIGITS :: "0123456789abcdef";
    if n == 0  return "0";
    digits: [16] u8;
    i := digits.count;
    v := n;
    while v > 0 { i -= 1; digits[i] = DIGITS[v % 16]; v /= 16; }
    s := alloc_string(digits.count - i);
    memcpy(s.data, digits.data + i, s.count);
    return s;
}

// Concatenate `parts` (the String module's join is not imported here; see index_of).
concat :: (parts: ..string) -> string {
    total := 0;
    for parts  total += it.count;
    s := alloc_string(total);
    at := 0;
    for parts { memcpy(s.data + at, it.data, it.count); at += it.count; }
    return s;
}
```

Replace `test_transfer_encoding_refused` (R5) with:

```jai
// R5, superseded. Transfer-Encoding used to be ignored, so a chunked body was parsed as further
// requests (desync); PR #5 refused it with 501. Now the body is decoded and the handler sees it.
test_chunked_request_decoded :: () {
    w: Worker;
    make_test_worker(*w, body_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    handle_client(*w, c, EPOLLIN);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(starts_with(as_string(got), "HTTP/1.1 200 ") && test_handler_calls == 1, "a chunked request is served once; handler ran %, got '%'", test_handler_calls, as_string(got));
    assert(string_equals(last_body(), "hello world"), "the handler sees the decoded body, got '%'", last_body());
    assert(c.state == .ACTIVE && !c.lingering, "the connection stays open after a chunked request");
    close_connection(*w, c);
    print("  PASS: test_chunked_request_decoded\n");
}
```

Add after the Task 1 chunked tests:

```jai
Framing_Case :: struct { fields: string; want: Parse_Error; }

// Spec §3.1: the first matching rule decides. Rules 1-4 are 400 (MALFORMED), rule 5 is 501.
test_transfer_encoding_rules :: () {
    cases := Framing_Case.[
        .{"Transfer-Encoding: chunked\r\nContent-Length: 5\r\n", .MALFORMED},    // rule 2: TE with CL
        .{"Transfer-Encoding: gzip\r\n", .MALFORMED},                            // rule 3: last coding is not chunked
        .{"Transfer-Encoding: chunked, gzip\r\n", .MALFORMED},
        .{"Transfer-Encoding: xchunked\r\n", .MALFORMED},
        .{"Transfer-Encoding: chunked;x=1\r\n", .MALFORMED},
        .{"Transfer-Encoding:\r\n", .MALFORMED},                                 // no codings at all
        .{"Transfer-Encoding: chunked, chunked\r\n", .MALFORMED},                // rule 4: chunked twice
        .{"Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", .MALFORMED},
        .{"Transfer-Encoding: gzip, chunked\r\n", .UNSUPPORTED_FRAMING},         // rule 5: unknown coding first
        .{"Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n", .UNSUPPORTED_FRAMING},
        .{"Transfer-Encoding: Chunked\r\n", .NONE},                              // rule 6: case-insensitive
        .{"Transfer-Encoding: , chunked ,\r\n", .NONE},                          // empty members are skipped
    ];
    for tc: cases {
        c := New(Connection);
        defer free(c);
        fill_request(c, tprint("POST / HTTP/1.1\r\nHost: x\r\n%\r\n0\r\n\r\n", tc.fields));
        r := parse_request(c);
        if tc.want == .NONE  assert(r == .COMPLETE && c.req.body.count == 0, "'%': expected an empty decoded body, got % (%)", tc.fields, r, c.parse_error);
        else                 assert(r == .ERROR && c.parse_error == tc.want, "'%': expected %, got % (%)", tc.fields, tc.want, r, c.parse_error);
    }
    // Rule 1: any Transfer-Encoding on HTTP/1.0 is faulty framing.
    c := New(Connection);
    defer free(c);
    fill_request(c, "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    r := parse_request(c);
    assert(r == .ERROR && c.parse_error == .MALFORMED, "TE on HTTP/1.0 must be MALFORMED, got % (%)", r, c.parse_error);
    print("  PASS: test_transfer_encoding_rules\n");
}

// Review focus 2. A trailer named Content-Length or Transfer-Encoding is discarded; it must not
// reframe anything. The pipelined request behind it parses intact.
test_chunked_trailers_cannot_reframe :: () {
    c := New(Connection);
    defer free(c);
    fill_request(c, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    r := parse_request(c);
    assert(r == .COMPLETE && string_equals(c.req.body, "hello") && c.req.header_count == 2, "first request: got % body '%' with % headers (%)", r, c.req.body, c.req.header_count, c.parse_error);
    reset_for_next_request(c);
    r = parse_request(c);
    assert(r == .COMPLETE && string_equals(c.req.method, "GET") && string_equals(c.req.path, "/b") && c.req.body.count == 0, "the pipelined GET parses intact: got % % '%' (%)",
        r, c.req.method, c.req.path, c.parse_error);
    assert(c.parse_offset == c.bytes_used, "nothing is left over: offset % of %", c.parse_offset, c.bytes_used);
    print("  PASS: test_chunked_trailers_cannot_reframe\n");
}

test_chunked_pipelined_with_get :: () {
    w: Worker;
    make_test_worker(*w, body_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    handle_client(*w, c, EPOLLIN);

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(test_handler_calls == 2 && count_occurrences(as_string(got), "HTTP/1.1 200 OK\r\n") == 2, "both requests served; handler ran %, got '%'", test_handler_calls, as_string(got));
    close_connection(*w, c);
    print("  PASS: test_chunked_pipelined_with_get\n");
}

// Review focus 3.
test_chunked_then_partial_next_request :: () {
    w: Worker;
    make_test_worker(*w, body_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\nGET /b HTTP/1.1\r\nHo");
    handle_client(*w, c, EPOLLIN);
    assert(test_handler_calls == 1 && string_equals(last_body(), "abc"), "the chunked request is served; handler ran %, body '%'", test_handler_calls, last_body());
    assert(c.parse_state == .HEADERS, "the partial GET waits in the buffer, got %", c.parse_state);

    send_to_server(peer, "st: x\r\n\r\n");
    handle_client(*w, c, EPOLLIN);
    assert(test_handler_calls == 2 && last_body_len == 0, "the completed GET is served with no body; handler ran %, body '%'", test_handler_calls, last_body());

    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(count_occurrences(as_string(got), "HTTP/1.1 200 OK\r\n") == 2, "two responses, got '%'", as_string(got));
    close_connection(*w, c);
    print("  PASS: test_chunked_then_partial_next_request\n");
}

// Review focus 4. The chunked request waits behind a stalled response and is decoded after the drain.
test_chunked_behind_stalled_response :: () {
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, mixed_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "GET /big HTTP/1.1\r\nHost: x\r\n\r\nPOST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    handle_client(*w, c, EPOLLIN);
    assert(c.pending.count > 0 && test_handler_calls == 1, "setup: the first response stalls and the chunked request waits; handler ran %", test_handler_calls);

    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while test_handler_calls < 2 || c.pending.count > 0 {
        got.count = 0;
        drain_peer(peer, *got);
        handle_client(*w, c, EPOLLOUT);
        rounds += 1;
        assert(rounds < 100000, "never drained");
    }
    assert(string_equals(last_body(), "hello"), "decoded after the drain, got '%'", last_body());
    close_connection(*w, c);
    print("  PASS: test_chunked_behind_stalled_response\n");
}

// Review focus 1. Exactly READ_BUFFER_SIZE (4096) is served; one byte more is 413.
test_chunked_buffer_edge :: () {
    head := "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    // head + "<3 hex digits>\r\n" + data + "\r\n" + "0\r\n\r\n" = 4096
    fits := 4096 - head.count - 3 - 2 - 2 - 5;
    assert(hex(fits).count == 3 && hex(fits + 1).count == 3, "setup: the size line has 3 hex digits");
    for extra: 0..1 {
        w: Worker;
        make_test_worker(*w, body_handler);
        defer destroy_test_worker(*w);
        server, peer := make_socket_pair();
        defer close(peer);
        c := attach(*w, server);

        data := big_body(fits + extra);
        defer free(data);
        msg := concat(head, hex(fits + extra), "\r\n", data, "\r\n0\r\n\r\n");
        defer free(msg);
        assert(msg.count == 4096 + extra, "setup: message is % bytes", msg.count);
        send_to_server(peer, msg);
        handle_client(*w, c, EPOLLIN);

        got: [..] u8;
        defer array_free(got);
        drain_peer(peer, *got);
        if extra == 0 {
            assert(starts_with(as_string(got), "HTTP/1.1 200 ") && last_body_len == fits, "a 4096-byte chunked request is served: got '%', body %", as_string(got), last_body_len);
        } else {
            assert(starts_with(as_string(got), "HTTP/1.1 413 ") && test_handler_calls == 0, "4097 bytes is 413: got '%'", as_string(got));
        }
        if c.state == .ACTIVE  close_connection(*w, c);
    }
    print("  PASS: test_chunked_buffer_edge\n");
}

test_chunked_trickle_gets_408 :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair();
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel");
    handle_client(*w, c, EPOLLIN);
    assert(c.parse_state == .CHUNKED && timeout_state(c) == .BODY, "setup: mid-chunk, timed as BODY; got % / %", c.parse_state, timeout_state(c));
    c.request_start_ms = 0;   // pretend it started at the epoch

    closed := check_timeouts(*w, 29999);
    assert(closed == 0, "not yet");
    closed = check_timeouts(*w, 30000);
    assert(closed == 1 && (c.state == .FREE || c.lingering), "a trickled chunked body is reaped at 30 s, got closed=%", closed);
    got: [..] u8;
    defer array_free(got);
    drain_peer(peer, *got);
    assert(starts_with(as_string(got), "HTTP/1.1 408 "), "a body timeout gets 408, got '%'", as_string(got));
    if c.state == .ACTIVE  close_connection(*w, c);
    print("  PASS: test_chunked_trickle_gets_408\n");
}
```

In `main`: delete `test_transfer_encoding_refused();` from "Event handling:", and extend "Chunked bodies:":

```jai
    test_transfer_encoding_rules();
    test_chunked_request_decoded();
    test_chunked_trailers_cannot_reframe();
    test_chunked_pipelined_with_get();
    test_chunked_then_partial_next_request();
    test_chunked_behind_stalled_response();
    test_chunked_buffer_edge();
    test_chunked_trickle_gets_408();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: the http_server suite compiles and fails its first new assertion: `test_transfer_encoding_rules` reports `'Transfer-Encoding: chunked\r\nContent-Length: 5\r\n': expected MALFORMED, got ERROR (UNSUPPORTED_FRAMING)` (today every TE is 501).

- [ ] **Step 3: Add `next_list_member` and use it in `determine_keep_alive`**

In the `#scope_file` region:

```jai
// Pop the next comma-separated member off `rest`, OWS-trimmed (RFC 9110 §5.6.1). Empty members
// come back as empty strings; `rest` is empty once the list is exhausted.
next_list_member :: (rest: *string) -> string {
    comma := find_byte(rest.data, 0, rest.count, #char ",");
    end   := ifx comma < 0 then rest.count else comma;
    member := trim_ows(make_view(rest.data, 0, end));
    skip  := ifx comma < 0 then rest.count else comma + 1;
    rest.data  += skip;
    rest.count -= skip;
    return member;
}
```

Replace `determine_keep_alive`'s inner loop:

```jai
determine_keep_alive :: (req: *Request) {
    saw_close, saw_keep_alive := false, false;
    for i: 0..cast(s64) req.header_count - 1 {
        if !string_equals_ci(req.headers[i].name, "Connection")  continue;
        rest := req.headers[i].value;
        while rest.count > 0 {
            option := next_list_member(*rest);
            if string_equals_ci(option, "close")       saw_close = true;
            if string_equals_ci(option, "keep-alive")  saw_keep_alive = true;
        }
    }
    req.keep_alive = req.http_version[7] != #char "0";
    if saw_keep_alive  req.keep_alive = true;
    if saw_close       req.keep_alive = false;
}
```

- [ ] **Step 4: Add `transfer_coding_error` and rewrite `finish_headers`**

```jai
// How a request carrying Transfer-Encoding is framed (spec §3.1; RFC 9112 §6.1, §6.3). NONE means
// exactly `chunked`. Codings are collected from every Transfer-Encoding field in order; empty list
// members are skipped, and only the bare token `chunked` (any case) counts as chunked.
transfer_coding_error :: (req: *Request, has_content_length: bool) -> Parse_Error {
    if req.http_version[7] == #char "0"  return .MALFORMED;   // rule 1: on HTTP/1.0 the framing is faulty
    if has_content_length                return .MALFORMED;   // rule 2: TE with CL, the smuggling shape
    codings, chunked_count := 0, 0;
    last_is_chunked := false;
    for i: 0..cast(s64) req.header_count - 1 {
        if !string_equals_ci(req.headers[i].name, "Transfer-Encoding")  continue;
        rest := req.headers[i].value;
        while rest.count > 0 {
            coding := next_list_member(*rest);
            if coding.count == 0  continue;
            codings += 1;
            last_is_chunked = string_equals_ci(coding, "chunked");
            if last_is_chunked  chunked_count += 1;
        }
    }
    if !last_is_chunked   return .MALFORMED;             // rule 3 (no codings at all, too)
    if chunked_count > 1  return .MALFORMED;             // rule 4: chunked applied twice
    if codings > 1        return .UNSUPPORTED_FRAMING;   // rule 5: a coding before chunked we cannot undo
    return .NONE;                                        // rule 6
}

// Validate the complete header block and settle the request's framing and keep-alive. Framing is
// checked first, since it decides where the next request starts; then Host. `next` is the state
// the body is read in: COMPLETE (no body), BODY (Content-Length) or CHUNKED.
finish_headers :: (c: *Connection) -> (error: Parse_Error, next: Parse_State) {
    req := *c.req;
    content_length: s64 = -1;
    host_count := 0;
    host_valid := true;
    has_transfer_encoding := false;
    for i: 0..cast(s64) req.header_count - 1 {
        h := *req.headers[i];
        if string_equals_ci(h.name, "Transfer-Encoding")  has_transfer_encoding = true;
        if string_equals_ci(h.name, "Content-Length") {
            value, valid, too_large := parse_content_length(h.value);
            if !valid      return .MALFORMED, .ERROR;
            if too_large   return .BODY_TOO_LARGE, .ERROR;
            // RFC 9112 §6.3: differing Content-Length values make the framing unrecoverable.
            if content_length >= 0 && value != content_length  return .MALFORMED, .ERROR;
            content_length = value;
        }
        if string_equals_ci(h.name, "Host") {
            host_count += 1;
            if !is_host_value(h.value)  host_valid = false;
        }
    }
    next := Parse_State.COMPLETE;
    if has_transfer_encoding {
        te_error := transfer_coding_error(req, content_length >= 0);
        if te_error != .NONE  return te_error, .ERROR;
        next = .CHUNKED;
    } else if content_length > 0 {
        if content_length > cast(s64) READ_BUFFER_SIZE - c.parse_offset  return .BODY_TOO_LARGE, .ERROR;   // won't fit
        req.content_length = content_length;
        next = .BODY;
    }
    // RFC 9112 §3.2: 400 for more than one Host, an invalid one, and an HTTP/1.1 request without one.
    if host_count > 1 || !host_valid  return .MALFORMED, .ERROR;
    if host_count == 0 && req.http_version[7] != #char "0"  return .MALFORMED, .ERROR;
    determine_keep_alive(req);
    return .NONE, next;
}
```

Update the `UNSUPPORTED_FRAMING` comment in `Parse_Error`:

```jai
    UNSUPPORTED_FRAMING   :: 4;   // 501: a transfer coding other than chunked (RFC 9112 §6.1)
```

- [ ] **Step 5: Enter `CHUNKED` from `parse_request`**

Replace the end-of-headers branch inside the HEADERS loop:

```jai
            if crlf == c.parse_offset {
                // Empty line — end of headers
                c.parse_offset = crlf + 2;
                header_error, next := finish_headers(c);
                if header_error != .NONE  return parse_fail(c, header_error);
                c.parse_state = next;
                if next == .COMPLETE  return .COMPLETE;
                if next == .CHUNKED {
                    c.chunk_phase = .SIZE;
                    c.body_start  = c.parse_offset;
                    c.body_end    = c.parse_offset;
                }
                break;  // BODY or CHUNKED: continue below
            }
```

and add, right after the HEADERS block and before the BODY block:

```jai
    if c.parse_state == .CHUNKED  return parse_chunked(c);
```

- [ ] **Step 6: One reset for every per-request field**

In `http.jai`, after `reset_request`:

```jai
// Return the parser to the start of a request. get_connection and reset_for_next_request both
// call this, so the per-request fields they clear cannot drift apart (the R11 lesson).
reset_parse :: (c: *Connection) {
    c.parse_state     = .REQUEST_LINE;
    c.parse_error     = .NONE;
    c.chunk_phase     = .SIZE;
    c.chunk_remaining = 0;
    c.body_start      = 0;
    c.body_end        = 0;
    reset_request(*c.req);
}
```

In `reset_for_next_request`, replace the three lines `c.parse_state = .REQUEST_LINE; c.parse_error = .NONE; reset_request(*c.req);` with `reset_parse(c);`. In `get_connection` (`connection.jai`), replace `c.parse_state = .REQUEST_LINE;`, `c.parse_error = .NONE;` and `reset_request(*c.req);` with `reset_parse(c);`.

- [ ] **Step 7: The server side: 413 and the BODY timeout**

In `server.jai`, `timeout_state`:

```jai
    if c.parse_state == .BODY || c.parse_state == .CHUNKED  return .BODY;
```

In `read_and_dispatch`, the buffer-full refusal:

```jai
            // A full buffer with no complete request: the request line (414), the header block
            // (431) or a chunked body (413) alone exceeds READ_BUFFER_SIZE.
            status: u16 = 431;
            if c.parse_state == .REQUEST_LINE  status = 414;
            if c.parse_state == .CHUNKED       status = 413;
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: every suite passes; the http_server suite prints PASS for the eight Task 2 tests and still passes `test_connection_option_list`, `test_duplicate_content_length_rejected` and `test_host_required_once`.

- [ ] **Step 9: Commit**

```bash
git add modules/http_server/http.jai modules/http_server/connection.jai modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: decode chunked request bodies (RFC 9112 framing rules)

finish_headers applies the Transfer-Encoding rules (TE with CL, TE on
HTTP/1.0, a final coding other than chunked, chunked twice: 400; another
coding before chunked: 501) and picks the body state; parse_request enters
CHUNKED. A chunked body that fills the read buffer is 413 and is timed as
BODY. reset_parse clears every per-request field in both reset paths.
Replaces the R5 test: chunked requests are now served.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Minimum drain rate

**Files:**
- Modify: `modules/http_server/module.jai` (`MIN_SEND_RATE`)
- Modify: `modules/http_server/connection.jai` (`write_deadline_ms`; cleared in `get_connection` and `release_pending`)
- Modify: `modules/http_server/server.jai` (`TIMEOUTS_ENABLED`, `drain_deadline`, `start_write_clock`, `write_too_slow`, `is_timed_out`, `check_timeouts`, `dispatch_buffered`, `refuse_and_close`, the overflow `#assert`)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Produces: `MIN_SEND_RATE : s64 = 16384`; `Connection.write_deadline_ms: s64`; `drain_deadline :: (now: s64, bytes: s64, grace_ms: s64, rate: s64) -> s64`; `start_write_clock :: (c: *Connection, now: s64)`; `write_too_slow :: (c: *Connection, now: s64) -> bool` (all exported from `server.jai`).

- [ ] **Step 1: Write the failing tests**

Add after `test_reads_do_not_extend_write_timeout`:

```jai
test_drain_deadline :: () {
    assert(drain_deadline(1000, 16384, 30000, 16384) == 32000, "16 KB at 16 KB/s: one second after the grace");
    assert(drain_deadline(1000, 1048576, 30000, 16384) == 95000, "1 MB at 16 KB/s: 64 s after the grace");
    assert(drain_deadline(1000, 0, 30000, 16384) == 31000, "an empty tail: just the grace");
    assert(drain_deadline(1000, 100, 0, 1000) == 1100, "no grace: size over rate alone");
    assert(drain_deadline(1000, 1048576, 30000, 0) == 0, "rate 0: no floor, no deadline");
    print("  PASS: test_drain_deadline\n");
}

// Defaults asserted as literals: MIN_SEND_RATE 16384, WRITE_TIMEOUT_MS 30000.
test_start_write_clock_sets_the_deadline :: () {
    c: Connection;
    c.pending.count = 32768;   // synthetic tail
    start_write_clock(*c, 5000);
    assert(c.last_write_ms == 5000, "the WRITE clock starts now, got %", c.last_write_ms);
    assert(c.write_deadline_ms == 5000 + 30000 + 2000, "32 KB at 16 KB/s after a 30 s grace, got %", c.write_deadline_ms);
    c.pending.count = 0;
    print("  PASS: test_start_write_clock_sets_the_deadline\n");
}

test_rate_floor_catches_a_steady_trickle :: () {
    c: Connection;
    c.pending.count     = 1;       // synthetic tail; the deadline is set directly
    c.write_deadline_ms = 94000;
    c.last_write_ms     = 93000;   // progress a second ago: not a stall
    t, s := is_timed_out(*c, 93999);
    assert(!t && s == .WRITE, "before its deadline a progressing tail is fine");
    c.last_write_ms = 93500;
    t, s = is_timed_out(*c, 94000);
    assert(t && s == .WRITE, "a tail that keeps trickling still times out at its deadline");
    c.write_deadline_ms = 0;       // no floor: only a stall counts
    c.last_write_ms     = 199000;
    t, s = is_timed_out(*c, 200000);
    assert(!t, "without a deadline, steady progress never times out");
    c.pending.count = 0;
    print("  PASS: test_rate_floor_catches_a_steady_trickle\n");
}

// Review focus 5 (deadline half). A 400 queued behind a full socket is a tail like any other.
test_canned_tail_gets_a_drain_deadline :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);

    filler: [1024] u8;
    while send(server, filler.data, filler.count, .NOSIGNAL) > 0 {}   // the socket is full
    send_to_server(peer, "GARBAGE\r\n\r\n");
    handle_client(*w, c, EPOLLIN);
    assert(c.pending.count > 0 && c.close_after_send, "setup: the 400 is queued behind the full socket");
    want := c.last_write_ms + 30000 + c.pending.count * 1000 / 16384;
    assert(c.write_deadline_ms == want, "a queued canned reply gets a drain deadline: % vs %", c.write_deadline_ms, want);
    close_connection(*w, c);
    print("  PASS: test_canned_tail_gets_a_drain_deadline\n");
}

test_check_timeouts_closes_a_slow_drain :: () {
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, big_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);

    send_to_server(peer, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    handle_client(*w, c, EPOLLIN);
    assert(c.pending.count > 0, "setup: the response stalls");
    want := c.last_write_ms + 30000 + c.pending.count * 1000 / 16384;
    assert(c.write_deadline_ms == want, "the dispatch path starts the drain clock: % vs %", c.write_deadline_ms, want);

    rec: Error_Recorder;
    ctx := context;
    ctx.logger      = record_errors;
    ctx.logger_data = *rec;
    now := c.write_deadline_ms;
    c.last_write_ms = now - 1000;   // progress a second ago: not a stall
    closed: s32;
    push_context ctx { closed = check_timeouts(*w, now); }
    assert(closed == 1 && c.state == .FREE, "a tail past its drain deadline is closed; closed=% state=%", closed, c.state);
    assert(rec.errors == 0, "a slow client is the client's doing: info, not an error (got % errors)", rec.errors);
    print("  PASS: test_check_timeouts_closes_a_slow_drain\n");
}
```

Register in `main` under "Timeouts:", after `test_reads_do_not_extend_write_timeout();`:

```jai
    test_drain_deadline();
    test_start_write_clock_sets_the_deadline();
    test_rate_floor_catches_a_steady_trickle();
    test_canned_tail_gets_a_drain_deadline();
    test_check_timeouts_closes_a_slow_drain();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile errors: `drain_deadline`, `start_write_clock` undeclared; `write_deadline_ms` is not a member of `Connection`.

- [ ] **Step 3: The parameter and the field**

In `module.jai`, after `WRITE_TIMEOUT_MS`:

```jai
    // Minimum average rate, in bytes per second, at which a queued response tail must drain once
    // the WRITE_TIMEOUT_MS grace has passed: a tail of N bytes must be gone within
    // WRITE_TIMEOUT_MS + N / MIN_SEND_RATE. The WRITE timeout alone only catches a stall; this
    // bounds how long a reader that trickles may hold its tail. 0: no floor.
    MIN_SEND_RATE       : s64 = 16384,
```

(`WRITE_TIMEOUT_MS` is now followed by a comma; keep `LINGER_TIMEOUT_MS` last.)

In `connection.jai`, add to `Connection` after `last_write_ms`:

```jai
    write_deadline_ms: s64;     // the queued tail must have drained by then (MIN_SEND_RATE); 0: none
```

In `get_connection`, after `c.last_write_ms = 0;`: `c.write_deadline_ms = 0;`. In `release_pending`, after `c.pending_offset = 0;`: `c.write_deadline_ms = 0;   // a deadline never outlives its tail`.

- [ ] **Step 4: Deadline helpers and the WRITE check**

In `server.jai`, change `TIMEOUTS_ENABLED` and add the helpers after `is_timed_out`'s doc block:

```jai
TIMEOUTS_ENABLED :: IDLE_TIMEOUT_MS > 0 || HEADER_TIMEOUT_MS > 0 || BODY_TIMEOUT_MS > 0 || WRITE_TIMEOUT_MS > 0 || LINGER_TIMEOUT_MS > 0 || MIN_SEND_RATE > 0;

// drain_deadline multiplies a tail's size by 1000, and arithmetic overflow is FATAL in every build.
#assert MAX_PENDING_BYTES <= 9000000000000 "MAX_PENDING_BYTES is too large for drain_deadline's arithmetic";

// When a tail of `bytes` queued at `now` must have drained to honor a minimum average rate after a
// grace period: now + grace_ms + bytes / rate (rate in bytes per second). 0 when rate <= 0: no
// floor. Takes its limits as arguments so tests can drive any value.
drain_deadline :: (now: s64, bytes: s64, grace_ms: s64, rate: s64) -> s64 {
    if rate <= 0  return 0;
    return now + grace_ms + bytes * 1000 / rate;
}

// A response tail was just queued: start the clocks the WRITE timeout and the rate floor read.
start_write_clock :: (c: *Connection, now: s64) {
    c.last_write_ms     = now;
    c.write_deadline_ms = drain_deadline(now, c.pending.count, WRITE_TIMEOUT_MS, MIN_SEND_RATE);
}

// The queued tail has missed its drain deadline, however steadily it has been moving.
write_too_slow :: inline (c: *Connection, now: s64) -> bool {
    return c.write_deadline_ms > 0 && now >= c.write_deadline_ms;
}
```

Replace `is_timed_out`:

```jai
is_timed_out :: (c: *Connection, now: s64) -> (timed_out: bool, state: Timeout_State) {
    state := timeout_state(c);
    if state == .WRITE {
        // Two limits on a queued tail: a stall (no progress for WRITE_TIMEOUT_MS; input does not
        // count) and the rate floor (not drained by its deadline, however steadily it trickles).
        stalled := WRITE_TIMEOUT_MS > 0 && now - c.last_write_ms >= WRITE_TIMEOUT_MS;
        return stalled || write_too_slow(c, now), state;
    }
    limit: s64 = 0;
    since: s64 = 0;
    if state == {
        case .IDLE;   limit = IDLE_TIMEOUT_MS;   since = c.last_activity_ms;
        case .HEADER; limit = HEADER_TIMEOUT_MS; since = c.request_start_ms;
        case .BODY;   limit = BODY_TIMEOUT_MS;   since = c.request_start_ms;
        case .LINGER; limit = LINGER_TIMEOUT_MS; since = c.last_activity_ms;   // set on entering linger
        case;         return false, state;
    }
    if limit <= 0  return false, state;
    return now - since >= limit, state;
}
```

Replace `check_timeouts` (one log line per close; the 408 path logs through `refuse_and_close`):

```jai
// Close every active connection whose timeout has passed. Returns how many were closed. A slow
// request gets a 408 through refuse_and_close (which logs it): the client may still be sending, so
// the reply needs the same drain-before-close to survive. Every other timeout closes silently.
check_timeouts :: (w: *Worker, now: s64) -> s32 {
    closed: s32 = 0;
    for * w.pool.connections {
        c := it;
        if c.state != .ACTIVE || c == w.listen_conn  continue;
        timed_out, state := is_timed_out(c, now);
        if !timed_out  continue;
        if state == .HEADER || state == .BODY {
            refuse_and_close(w, c, 408);
        } else {
            detail := ifx state == .WRITE && write_too_slow(c, now) then " (drained slower than MIN_SEND_RATE)" else "";
            Basic.log("fd %: % timeout%; closing", c.fd, state, detail);
            close_connection(w, c);
        }
        closed += 1;
    }
    return closed;
}
```

- [ ] **Step 5: Start the clock where tails are queued**

In `dispatch_buffered`, replace

```jai
        now := now_ms();
        c.last_activity_ms = now;
        c.last_write_ms    = now;   // a tail queued now starts the WRITE clock

        if wr == .ERROR { close_connection(w, c); return false; }
```

with

```jai
        now := now_ms();
        c.last_activity_ms = now;
        if wr == .ERROR { close_connection(w, c); return false; }
        if wr == .PENDING  start_write_clock(c, now);   // the WRITE and drain-rate clocks
```

In `refuse_and_close`, replace `c.last_write_ms = now_ms();` in the PENDING branch with `start_write_clock(c, now_ms());`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: every suite passes, including the existing `test_is_timed_out_write_then_idle`, `test_reads_do_not_extend_write_timeout` and `test_check_timeouts_sends_408_for_a_slow_header`.

- [ ] **Step 7: Commit**

```bash
git add modules/http_server/module.jai modules/http_server/connection.jai modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: minimum drain rate for queued response tails (MIN_SEND_RATE)

A queued tail must drain within WRITE_TIMEOUT_MS + size / MIN_SEND_RATE
(default 16 KB/s), on top of the existing no-progress check, so a reader
that trickles can no longer hold its tail and slot indefinitely. The sweep
logs one line per timeout close, naming a missed drain deadline.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Per-worker pending budget and the refusal report

**Files:**
- Modify: `modules/http_server/module.jai` (`MAX_PENDING_PER_WORKER`)
- Modify: `modules/http_server/connection.jai` (`pool`, `pending_charge`, pool totals and counters, `init_pool`, `release_pending`, new `Tail_Refusal`, `tail_refusal`, `reserve_tail`)
- Modify: `modules/http_server/http.jai` (`write_response`, `write_or_queue` reserve through `reserve_tail`)
- Modify: `modules/http_server/server.jai` (`report_refused_tails`, `worker_sweep`, `worker_run`, the sweep comment)
- Test: `modules/http_server/tests/test.jai` (`standalone_pool`, `test_write_response_cap_exceeded`, new tests)

**Interfaces:**
- Consumes: `release_pending` clearing `write_deadline_ms` (Task 3).
- Produces: `MAX_PENDING_PER_WORKER : s64 = 67108864`; `Connection.pool: *Connection_Pool`, `Connection.pending_charge: s64`; `Connection_Pool.pending_total`, `refused_over_connection`, `refused_over_budget: s64`; `Tail_Refusal :: enum u8 #specified { NONE :: 0; OVER_CONNECTION_CAP :: 1; OVER_WORKER_BUDGET :: 2; }`; `tail_refusal :: (unsent: s64, worker_total: s64, connection_cap: s64, worker_budget: s64) -> Tail_Refusal`; `reserve_tail :: (c: *Connection, unsent: s64) -> Tail_Refusal`; `report_refused_tails :: (w: *Worker)`.

- [ ] **Step 1: Write the failing tests**

Give standalone connections an accounting pool (replace `standalone_connection`):

```jai
// Accounting home for standalone connections: the writer charges every queued tail to the
// connection's pool and release_pending refunds it. A shared zero-slot pool, not a real one:
// tests free() standalone connections individually.
standalone_pool: Connection_Pool;

// A Connection outside any worker with its pending allocator pinned, for writer-level tests.
standalone_connection :: (fd: s32) -> *Connection {
    c := New(Connection);
    c.pending.allocator = context.allocator;
    c.pool = *standalone_pool;
    c.fd = fd;
    return c;
}
```

In `test_write_response_cap_exceeded`, count the refusal: before the `write_response` call add `before := standalone_pool.refused_over_connection;`, and after the two existing asserts add:

```jai
    assert(standalone_pool.refused_over_connection == before + 1, "the refusal is counted for the sweep's report");
```

In `test_pending_defaults_and_release`, after `c := get_connection(*pool);` add:

```jai
    assert(c.pool == *pool, "init_pool points every connection at its pool");
```

and after the final `free_connection` asserts:

```jai
    assert(pool.pending_total == 0, "a tail appended without a reservation is never charged, so nothing is refunded");
```

New tests, as a "Pending budget:" group:

```jai
test_tail_refusal :: () {
    assert(tail_refusal(100, 0, 1000, 5000) == .NONE, "small tail, empty worker");
    assert(tail_refusal(1000, 0, 1000, 5000) == .NONE, "exactly the connection cap fits");
    assert(tail_refusal(1001, 0, 1000, 5000) == .OVER_CONNECTION_CAP, "one byte over the connection cap");
    assert(tail_refusal(1000, 4000, 1000, 5000) == .NONE, "exactly the worker budget fits");
    assert(tail_refusal(1000, 4001, 1000, 5000) == .OVER_WORKER_BUDGET, "one byte over the worker budget");
    assert(tail_refusal(2000, 4500, 1000, 5000) == .OVER_CONNECTION_CAP, "the connection cap is checked first");
    assert(tail_refusal(1, 0, 0, 5000) == .OVER_CONNECTION_CAP, "a cap of 0 queues nothing");
    print("  PASS: test_tail_refusal\n");
}

// The test that matters most: a refund missed on any path would leak budget until the worker
// refused every large response, a slow-motion outage. Review focus 5 (charge half) is step 3.
test_pending_budget_accounting_balances :: () {
    assert(standalone_pool.pending_total == 0, "the writer tests left % bytes charged", standalone_pool.pending_total);
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, big_handler);
    defer destroy_test_worker(*w);
    s1, p1 := make_socket_pair(server_sndbuf = 4096);
    defer close(p1);
    s2, p2 := make_socket_pair(server_sndbuf = 4096);
    defer close(p2);
    c1 := attach(*w, s1);
    c2 := attach(*w, s2);

    send_to_server(p1, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    send_to_server(p2, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    handle_client(*w, c1, EPOLLIN);
    handle_client(*w, c2, EPOLLIN);
    assert(c1.pending.count > 0 && c2.pending.count > 0, "setup: both responses stall");
    assert(c1.pending_charge == c1.pending.allocated && c2.pending_charge == c2.pending.allocated, "each tail is charged its reservation");
    assert(w.pool.pending_total == c1.pending_charge + c2.pending_charge, "the pool total is the sum of its tails: % vs % + %",
        w.pool.pending_total, c1.pending_charge, c2.pending_charge);

    // 1. A drained tail is refunded.
    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while c1.pending.count > 0 {
        got.count = 0;
        drain_peer(p1, *got);
        handle_client(*w, c1, EPOLLOUT);
        rounds += 1;
        assert(rounds < 100000, "never drained");
    }
    assert(c1.pending_charge == 0 && w.pool.pending_total == c2.pending_charge, "a drained tail is refunded, total now %", w.pool.pending_total);

    // 2. A connection closed with its tail queued is refunded.
    close_connection(*w, c2);
    assert(w.pool.pending_total == 0, "a closed connection's tail is refunded, total now %", w.pool.pending_total);

    // 3. A canned reply queued behind a full socket is charged and refunded the same way.
    filler: [1024] u8;
    while send(s1, filler.data, filler.count, .NOSIGNAL) > 0 {}
    send_to_server(p1, "GARBAGE\r\n\r\n");
    handle_client(*w, c1, EPOLLIN);
    assert(c1.pending.count > 0 && c1.pending_charge > 0 && w.pool.pending_total == c1.pending_charge, "a queued canned reply is charged: total % vs charge %",
        w.pool.pending_total, c1.pending_charge);
    close_connection(*w, c1);
    assert(w.pool.pending_total == 0, "and refunded, total now %", w.pool.pending_total);
    print("  PASS: test_pending_budget_accounting_balances\n");
}

// Defaults asserted as literals: MAX_PENDING_PER_WORKER 67108864.
test_pending_budget_refuses_and_reports :: () {
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, big_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);
    w.pool.pending_total = 67108864 - 1000;   // synthetic: the worker budget is all but spent

    rec: Error_Recorder;
    ctx := context;
    ctx.logger      = record_errors;
    ctx.logger_data = *rec;
    send_to_server(peer, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    push_context ctx { handle_client(*w, c, EPOLLIN); }
    assert(c.state == .FREE, "a tail over the worker budget closes its connection");
    assert(w.pool.refused_over_budget == 1 && w.pool.refused_over_connection == 0, "counted as a budget refusal: % / %", w.pool.refused_over_budget, w.pool.refused_over_connection);
    assert(w.pool.pending_total == 67108864 - 1000, "a refused tail charges nothing");
    assert(rec.errors == 0, "the refusal itself logs nothing; the sweep reports it (got %)", rec.errors);

    push_context ctx { worker_sweep(*w, now_ms()); }
    assert(rec.errors == 1, "one summary line per sweep, got %", rec.errors);
    assert(w.pool.refused_over_budget == 0, "the sweep resets the counts");
    push_context ctx { worker_sweep(*w, now_ms()); }
    assert(rec.errors == 1, "nothing to report, nothing logged (got %)", rec.errors);
    w.pool.pending_total = 0;
    print("  PASS: test_pending_budget_refuses_and_reports\n");
}
```

In `main`, after the "Timeouts:" group:

```jai
    print("\nPending budget:\n");
    test_tail_refusal();
    test_pending_budget_accounting_balances();
    test_pending_budget_refuses_and_reports();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile errors: `pool` is not a member of `Connection`; `refused_over_connection`, `pending_total` are not members of `Connection_Pool`; `tail_refusal` undeclared.

- [ ] **Step 3: The parameter, fields and accounting**

In `module.jai`, after `MAX_PENDING_BYTES`:

```jai
    // Cap on the response tail bytes all of one worker's connections may queue together. A tail
    // that would push the worker past it closes its connection, as MAX_PENDING_BYTES does. Without
    // it every pool slot could hold MAX_PENDING_BYTES (16 workers x 1024 slots x 1 MB = 16 GB). Like
    // MAX_PENDING_BYTES, 0 is literal: no tail may be queued.
    MAX_PENDING_PER_WORKER : s64 = 67108864,
```

In `connection.jai`, add to `Connection` after `pending_offset`:

```jai
    pending_charge:   s64;      // bytes of this tail charged to pool.pending_total (reserve_tail)
    pool:             *Connection_Pool;   // the owning pool, one per worker; set in init_pool
```

Add to `Connection_Pool`:

```jai
    pending_total:           s64;   // bytes reserved by every queued tail in this pool
    refused_over_connection: s64;   // tail refusals since the last sweep, by reason
    refused_over_budget:     s64;
```

In `init_pool`'s loop, after `c.pending.allocator = context.allocator;`: `c.pool = pool;`.

Replace `release_pending` and add the accounting procs after it:

```jai
// Free the queued tail, refund its charge to the worker budget, and reset the cursor. array_reset
// frees through the array's own (pinned) allocator and keeps it set. Guarded on data: Basic.free
// calls the allocator proc unconditionally, so an empty array on a slot that was never pinned must
// not reach it. This is the one place every tail ends (drain, close, slot reuse, pool
// destruction), so the refund cannot be missed. Idempotent.
release_pending :: (c: *Connection) {
    if c.pending.data  Basic.array_reset(*c.pending);
    c.pending_offset    = 0;
    c.write_deadline_ms = 0;   // a deadline never outlives its tail
    if c.pending_charge > 0 {
        c.pool.pending_total -= c.pending_charge;
        c.pending_charge = 0;
    }
}

Tail_Refusal :: enum u8 #specified {
    NONE                :: 0;
    OVER_CONNECTION_CAP :: 1;   // the tail alone exceeds MAX_PENDING_BYTES
    OVER_WORKER_BUDGET  :: 2;   // the worker's queued tails would exceed MAX_PENDING_PER_WORKER
}

// Whether a tail of `unsent` bytes may queue, given the worker's queued total and both caps.
// Takes the caps as arguments so tests can drive any value.
tail_refusal :: (unsent: s64, worker_total: s64, connection_cap: s64, worker_budget: s64) -> Tail_Refusal {
    if unsent > connection_cap                return .OVER_CONNECTION_CAP;
    if worker_total + unsent > worker_budget  return .OVER_WORKER_BUDGET;
    return .NONE;
}

// Reserve room in c.pending for a tail of `unsent` bytes and charge it to the worker budget. On a
// refusal nothing is reserved and the refusal is counted on the pool; worker_sweep reports the
// counts once a second (a client can trigger a refusal on every request). Requires an empty queue.
reserve_tail :: (c: *Connection, unsent: s64) -> Tail_Refusal {
    refusal := tail_refusal(unsent, c.pool.pending_total, MAX_PENDING_BYTES, MAX_PENDING_PER_WORKER);
    if refusal == .OVER_CONNECTION_CAP { c.pool.refused_over_connection += 1; return refusal; }
    if refusal == .OVER_WORKER_BUDGET  { c.pool.refused_over_budget     += 1; return refusal; }
    Basic.array_reserve(*c.pending, unsent);
    c.pending_charge = c.pending.allocated;
    c.pool.pending_total += c.pending_charge;
    return .NONE;
}
```

- [ ] **Step 4: Both writers reserve through `reserve_tail`**

In `write_response` (`http.jai`), replace the cap check

```jai
    unsent := total - sent;
    if unsent > MAX_PENDING_BYTES {
        // A failure to serve: the client receives a body shorter than its Content-Length.
        Basic.log_error("fd %: unsent response tail of % bytes exceeds MAX_PENDING_BYTES (%); closing", c.fd, unsent, MAX_PENDING_BYTES);
        return .ERROR;
    }
```

with

```jai
    // A refusal is a failure to serve (the client receives a body shorter than its Content-Length).
    // reserve_tail counts it; worker_sweep reports it.
    if reserve_tail(c, total - sent) != .NONE  return .ERROR;
```

In `write_or_queue`, replace the `MAX_PENDING_BYTES` check and its `log_error` with:

```jai
    if reserve_tail(c, data.count - sent) != .NONE  return .ERROR;
```

The `append_bytes` calls stay; they now write into the exact reservation and never regrow.

- [ ] **Step 5: Report refusals from the sweep; always sweep**

In `server.jai`, replace `worker_sweep` and add the report:

```jai
// The once-a-second work of worker_run: timeouts, retrying accepts paused by fd or memory
// exhaustion (an edge-triggered listen socket would not report the waiting backlog again), and the
// tail-refusal report.
worker_sweep :: (w: *Worker, now: s64) {
    #if TIMEOUTS_ENABLED  check_timeouts(w, now);
    if w.accept_paused  accept_connections(w);
    report_refused_tails(w);
}

// Tail refusals are a failure to serve, but a client can trigger one per request: one log_error
// line per worker per second with the counts, not one per refusal.
report_refused_tails :: (w: *Worker) {
    p := *w.pool;
    if p.refused_over_connection == 0 && p.refused_over_budget == 0  return;
    Basic.log_error("Worker %: closed % connection(s) whose response tail exceeded MAX_PENDING_BYTES (%) and % that would have exceeded MAX_PENDING_PER_WORKER (%) in the last second",
        w.id, p.refused_over_connection, MAX_PENDING_BYTES, p.refused_over_budget, MAX_PENDING_PER_WORKER);
    p.refused_over_connection = 0;
    p.refused_over_budget     = 0;
}
```

In `worker_run`, replace

```jai
        wait_ms: s32 = -1;
        if TIMEOUTS_ENABLED || w.accept_paused  wait_ms = 1000;
        nfds := epoll_process_events(*w.engine, timeout_ms = wait_ms);
```

with

```jai
        // Wake at least once a second, whatever is enabled, so the sweep always runs: a refusal
        // count must never be stranded. A 1 Hz wakeup per worker costs nothing measurable.
        nfds := epoll_process_events(*w.engine, timeout_ms = 1000);
```

In the comment above `TIMEOUTS_ENABLED`, change "Sweeps run once a second from worker_run when any timeout is enabled." to "Sweeps run once a second from worker_run."

- [ ] **Step 6: Run the tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: every suite passes, including all existing writer, backpressure and pending-path tests.

- [ ] **Step 7: Commit**

```bash
git add modules/http_server/module.jai modules/http_server/connection.jai modules/http_server/http.jai modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: per-worker pending budget; tail refusals reported once a second

Every queued tail is reserved once at its exact size and charged to its
worker's pool; release_pending, the one place every tail ends, refunds it.
A tail past MAX_PENDING_BYTES or the new MAX_PENDING_PER_WORKER (64 MB)
closes its connection and is counted; worker_sweep reports the counts as one
log_error line per worker per second. The sweep now always runs.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: First-request deadline

**Files:**
- Modify: `modules/http_server/server.jai` (`Timeout_State`, `timeout_state`, `is_timed_out`, `accept_connections`)
- Test: `modules/http_server/tests/test.jai`

**Interfaces:**
- Consumes: `check_timeouts`' silent-close branch (Task 3).
- Produces: `Timeout_State.NEW :: 6`.

- [ ] **Step 1: Write the failing tests**

Add to the timeout tests:

```jai
// Defaults asserted as literals: HEADER_TIMEOUT_MS 10000.
test_new_connection_state :: () {
    c: Connection;
    c.request_start_ms = 5000;   // as accept_connections leaves a fresh connection
    assert(timeout_state(*c) == .NEW, "accepted, nothing received: NEW, got %", timeout_state(*c));
    t, s := is_timed_out(*c, 5000 + 9999);
    assert(!t && s == .NEW, "one ms short of 10 s is fine");
    t, s = is_timed_out(*c, 5000 + 10000);
    assert(t && s == .NEW, "a silent new connection times out HEADER_TIMEOUT_MS after accept");
    c.bytes_used  = 3;
    c.parse_state = .REQUEST_LINE;
    t, s = is_timed_out(*c, 5000 + 10000);
    assert(t && s == .HEADER, "once bytes arrive it is a HEADER wait, still timed from accept");
    print("  PASS: test_new_connection_state\n");
}

test_new_connection_closed_silently :: () {
    w: Worker;
    make_test_worker(*w, ok_handler);
    defer destroy_test_worker(*w);
    lfd := socket(AF_INET, .SOCK_STREAM | .SOCK_NONBLOCK | .SOCK_CLOEXEC, 0);
    assert(lfd >= 0 && bind(lfd, "127.0.0.1", 0) == 0 && listen(lfd, 16) == 0, "setup: listen socket");
    defer close(lfd);
    addr: sockaddr_in;
    len: socklen_t = size_of(sockaddr_in);
    getsockname(lfd, cast(*sockaddr) *addr, *len);
    client := socket(AF_INET, .SOCK_STREAM | .SOCK_CLOEXEC, 0);
    defer close(client);
    assert(connect(client, cast(*sockaddr) *addr, len) == 0, "setup: connect");
    fcntl(client, F_SETFL, O_NONBLOCK);

    w.listen_fd = lfd;
    accept_connections(*w);
    w.listen_fd = -1;
    c: *Connection;
    for * w.pool.connections  if it.state == .ACTIVE  c = it;
    assert(c != null && c.request_start_ms > 0 && timeout_state(c) == .NEW, "an accepted connection that sent nothing is NEW, timed from accept");
    accepted_at := c.request_start_ms;

    closed := check_timeouts(*w, accepted_at + 9999);
    assert(closed == 0 && c.state == .ACTIVE, "not yet");
    closed = check_timeouts(*w, accepted_at + 10000);
    assert(closed == 1 && c.state == .FREE, "closed HEADER_TIMEOUT_MS after accept; closed=% state=%", closed, c.state);

    got: [..] u8;
    defer array_free(got);
    n: s64;
    ended, err: s32;
    for 1..1000000 {   // the FIN is already on its way; no sleeping
        n, ended, err = client_read(client, *got);
        if ended != 0  break;
    }
    assert(ended == 1 && got.count == 0, "closed without a reply: EOF and no bytes; ended %, got '%'", ended, as_string(got));
    print("  PASS: test_new_connection_closed_silently\n");
}
```

Register in `main` under "Timeouts:", after `test_check_timeouts_closes_a_slow_drain();`:

```jai
    test_new_connection_state();
    test_new_connection_closed_silently();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: compile error: `NEW` is not a member of `Timeout_State`.

- [ ] **Step 3: Implement**

In `server.jai`, extend `Timeout_State`:

```jai
    NEW    :: 6;   // accepted, no byte received yet: the first request's HEADER clock, from accept
```

In `timeout_state`, replace `if c.bytes_used == 0 return .IDLE;` with:

```jai
    if c.bytes_used == 0 {
        // accept_connections stamps request_start_ms; the read path only sets it when it is zero
        // and reset_for_next_request clears it, so this combination means nothing has arrived yet.
        if c.request_start_ms != 0  return .NEW;
        return .IDLE;
    }
```

In `is_timed_out`'s switch, add:

```jai
        case .NEW;    limit = HEADER_TIMEOUT_MS; since = c.request_start_ms;   // from accept
```

In `accept_connections`, after `c.last_activity_ms = now_ms();`:

```jai
        c.request_start_ms = c.last_activity_ms;   // NEW: the first request is timed from accept, as nginx does
```

`check_timeouts` needs no change: `NEW` takes the silent-close branch (no 408: the client asked nothing, and a 408 racing its first request would be read as the answer to it).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: every suite passes, including `test_timeout_state_classification`, `test_check_timeouts_closes_idle_silently` (an `attach`ed connection is IDLE: `attach` does not stamp `request_start_ms`) and `test_paused_accept_retried_by_sweep`.

- [ ] **Step 5: Commit**

```bash
git add modules/http_server/server.jai modules/http_server/tests/test.jai
git commit -m "http_server: first-request deadline from accept (NEW timeout state)

A connection that has not sent a byte is NEW and gets HEADER_TIMEOUT_MS
(10 s) from accept instead of IDLE's 60 s, then closes without a reply, as
nginx's client_header_timeout does. Holding a slot with a silent socket now
costs six times as much.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Verification, benchmark, docs

**Files:**
- Modify: `README.md`, `CLAUDE.md`, this plan (appendix), the spec (status line)

- [ ] **Step 1: Full suites and examples, debug and release**

```bash
~/jai/jai/bin/jai-linux first.jai - run-tests
~/jai/jai/bin/jai-linux first.jai - run-tests -release
~/jai/jai/bin/jai-linux first.jai -
grep -cE '^    test_[a-z0-9_]+\(\);$' modules/http_server/tests/test.jai
```

Expected: every suite passes in both builds; all examples build without warnings; the count is 123 (102 + 21 new).

- [ ] **Step 2: Real-TCP checks with a scratch server**

Write `$SCRATCH/slow_clients.jai` (scratch, not committed; `$SCRATCH` is a directory outside the repo). It overrides the new parameters so the rate floor fires in seconds:

```jai
// Scratch: POST echoes the decoded body length; GET sends 4 MB. A raised tail cap keeps
// MAX_PENDING_BYTES out of the way, and a fast floor with a short grace makes MIN_SEND_RATE bite
// within seconds: a 4 MB tail must drain within 5 s + 16 s.
#import "http_server"()(MAX_PENDING_BYTES = 8388608, MIN_SEND_RATE = 262144, WRITE_TIMEOUT_MS = 5000);
#import "Basic";

big: string;

handler :: (request: *Request, response: *Response) {
    if request.body.count > 0 { response.body = sprint("%", request.body.count); return; }
    response.body = big;
}

main :: () {
    big = alloc_string(4 * 1048576);
    memset(big.data, #char "x", big.count);
    server: Server;
    if !init_server(*server, 2)  return;
    serve(*server, handler, null);
    if !server_listen(*server, "0.0.0.0", 9090)  return;
    server_run(*server);
}
```

```bash
cd $SCRATCH && ~/jai/jai/bin/jai-linux slow_clients.jai -import_dir /home/jim/projects/jai-http/modules
./slow_clients & SRV=$!
until curl -s -o /dev/null http://localhost:9090/; do :; done   # wait for the listener (no sleep)
head -c 3000 /dev/urandom > up.bin
curl -s -H 'Transfer-Encoding: chunked' -H 'Expect:' --data-binary @up.bin http://localhost:9090/; echo
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' --limit-rate 2M http://localhost:9090/
curl -s -o /dev/null -w '%{http_code} %{size_download} exit=' --limit-rate 64k http://localhost:9090/; echo $?
python3 -c "import socket,time;s=socket.create_connection(('127.0.0.1',9090));t=time.time();print(len(s.recv(100)), round(time.time()-t,1))"
kill $SRV; wait $SRV 2>/dev/null
```

Expected:
- the chunked upload prints `3000`;
- the 2 MB/s download completes: `200 4194304`;
- the 64 KB/s download is cut short (`size_download` well under 4194304, curl exit 18) and the server logs `WRITE timeout (drained slower than MIN_SEND_RATE); closing`;
- the silent socket prints `0 10.x` (EOF after about 10 s) and the server logs `NEW timeout; closing`.

Use `$!` and `kill $SRV`; never `pkill` (it can match the shell running the command).

- [ ] **Step 3: wrk A/B against master, same session**

```bash
git worktree add $SCRATCH/master-tree master
(cd $SCRATCH/master-tree && ~/jai/jai/bin/jai-linux first.jai - hello_world -release)
~/jai/jai/bin/jai-linux first.jai - hello_world -release
for build in $SCRATCH/master-tree/build_release/hello_world ./build_release/hello_world; do
    $build & SRV=$!
    until curl -s -o /dev/null http://localhost:9090/; do :; done   # wait for the listener (no sleep)
    for tc in "1 10" "4 100" "8 500" "16 1000" "32 2000"; do
        set -- $tc; wrk -t$1 -c$2 -d10s http://localhost:9090/ | grep -E "Requests/sec|Socket errors|Non-2xx"
    done
    kill $SRV; wait $SRV 2>/dev/null
done
git worktree remove $SCRATCH/master-tree
```

Expected: the branch is within noise of master at every point (the hot path gains one branch in `finish_headers`; t1/c10 is bimodal on this box, so judge it loosely), and no socket errors or non-2xx responses. A regression beyond noise blocks the PR: stop and investigate. Record both columns in the appendix below.

- [ ] **Step 4: Docs**

`README.md`, the `http_server` parameter table: add the `MAX_PENDING_PER_WORKER` row after `MAX_PENDING_BYTES`, replace the `HEADER_TIMEOUT_MS` row, add the `MIN_SEND_RATE` row after `WRITE_TIMEOUT_MS`, then re-align the table (`python3 ~/lighthouse/connecting-accounts/tools/align-md-tables.py README.md`):

```
| `MAX_PENDING_PER_WORKER` | 67108864 | Response bytes all of one worker's connections may queue together  |
| `HEADER_TIMEOUT_MS`      | 10000    | Until a request's headers are complete: from accept for a connection's first request, from the first byte after that |
| `MIN_SEND_RATE`          | 16384    | Bytes/s a queued response must average after the `WRITE_TIMEOUT_MS` grace (0: no floor) |
```

`CLAUDE.md`:
- **Current status:** add a sentence after the PR #5 review sentence: "Chunked request bodies are decoded in place under strict RFC 9112 framing rules, and slow clients are bounded three ways: a minimum drain rate for queued response tails (`MIN_SEND_RATE`), a per-worker budget for all tails together (`MAX_PENDING_PER_WORKER`), and a first-request deadline from accept. See `docs/plans/2026-10-03-chunked-and-slow-clients-{design,implementation}.md`." Update the test counts to 213 (123 http_server + 41 + 19 + 15 + 15).
- **`module.jai` bullet:** add `MIN_SEND_RATE` (16384) and `MAX_PENDING_PER_WORKER` (67108864) to the parameter list.
- **`http.jai` bullet:** mention `parse_chunked` (in-place decoding, strict grammar, trailers discarded), the Transfer-Encoding rules in `finish_headers`, `reset_parse`, and that tails are reserved through `reserve_tail`.
- **`connection.jai` bullet:** the chunk fields, `pool` back-pointer, `pending_charge`, pool `pending_total` and refusal counters, `reserve_tail`/`tail_refusal`, refund in `release_pending`.
- **`server.jai` bullet:** the `NEW` state, the drain deadline (`start_write_clock`, `drain_deadline`), CHUNKED → 413 on a full buffer, `report_refused_tails`, and that the sweep always runs.
- **Key Patterns:** after the `MAX_PENDING_BYTES` bullet add: "**Budget accounting has one refund point:** every tail is reserved once through `reserve_tail` and refunded in `release_pending`, the one place every tail ends; `test_pending_budget_accounting_balances` guards it, because a missed refund would slowly refuse everything."
- **Future Considerations:** in the fib-lifts DONE entry, replace the "Open from the review" sentence about chunked bodies and slow readers with "Both open items are done: see the chunked-and-slow-clients entry." and add a DONE entry for this work (what landed, the three spec deviations, the review-focus tests).
- **Benchmark History:** add a "chunked + slow clients" table from Step 3 (master vs branch, same session).

Run `python3 ~/lighthouse/connecting-accounts/tools/align-md-tables.py --check README.md CLAUDE.md docs/plans/2026-10-03-chunked-and-slow-clients-implementation.md`; expected: all tables aligned.

In the spec, change the status line to: `**Status:** implemented (plan: 2026-10-03-chunked-and-slow-clients-implementation.md).`

- [ ] **Step 5: Commit, push, open the PR**

```bash
git add README.md CLAUDE.md docs/plans/2026-10-03-chunked-and-slow-clients-design.md docs/plans/2026-10-03-chunked-and-slow-clients-implementation.md
git commit -m "docs: chunked bodies and slow-client defenses; wrk A/B against master

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin chunked-slow-clients
gh pr create --base master --title "Chunked request bodies and slow-client defenses" --body-file $SCRATCH/pr-body.md
```

Write `$SCRATCH/pr-body.md` first, with these sections: **Summary** (one line per code task: what it does and why, linking the spec); **Spec deviations** (the three listed under Global Constraints); **Review focus** (the five inputs and the test pinning each); **Verification** (suite counts in debug and release, the four real-TCP checks with their observed results, the wrk A/B table from the appendix). End the body with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

---

## Appendix: wrk A/B (Task 6, same session)

| wrk         | master | branch | delta |
|-------------|-------:|-------:|------:|
| t1 / c10    |        |        |       |
| t4 / c100   |        |        |       |
| t8 / c500   |        |        |       |
| t16 / c1000 |        |        |       |
| t32 / c2000 |        |        |       |
