
Header :: struct {
    name:  string;    // Zero-copy view into connection buffer (request) or user-provided (response)
    value: string;
}

Request :: struct {
    method:         string;
    path:           string;
    query_string:   string;
    http_version:   string;
    headers:        [MAX_HEADERS] Header;
    header_count:   s32;
    keep_alive:     bool;
    body:           string;
    content_length: s64;
}

Response :: struct {
    status_code:  u16 = 200;
    content_type: string = "text/plain";
    body:         string;
    headers:      [MAX_HEADERS] Header;
    header_count: s32;
}

Handler :: #type (request: *Request, response: *Response);

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

Parse_Result :: enum u8 #specified {
    INCOMPLETE :: 0;
    COMPLETE   :: 1;
    ERROR      :: 2;
}

// Why parse_request returned .ERROR; decides the canned reply (parse_error_status).
Parse_Error :: enum u8 #specified {
    NONE                  :: 0;
    MALFORMED             :: 1;   // 400
    BODY_TOO_LARGE        :: 2;   // 413
    TOO_MANY_HEADERS      :: 3;   // 431: more header fields than MAX_HEADERS
    UNSUPPORTED_FRAMING   :: 4;   // 501: a transfer coding other than chunked (RFC 9112 §6.1)
    VERSION_NOT_SUPPORTED :: 5;   // 505: a well-formed HTTP-version whose major version is not 1
}

// The canned status for a parse failure.
parse_error_status :: (e: Parse_Error) -> u16 {
    if e == {
        case .BODY_TOO_LARGE;        return 413;
        case .TOO_MANY_HEADERS;      return 431;
        case .UNSUPPORTED_FRAMING;   return 501;
        case .VERSION_NOT_SUPPORTED; return 505;
    }
    return 400;
}

// Look up a request header by name (case-insensitive).
get_header :: (request: *Request, name: string) -> (value: string, found: bool) {
    for i: 0..cast(s64) request.header_count - 1 {
        if string_equals_ci(request.headers[i].name, name) {
            return request.headers[i].value, true;
        }
    }
    result: string;
    return result, false;
}

// Add a custom header to the response.
set_header :: (response: *Response, name: string, value: string) {
    if response.header_count >= MAX_HEADERS return;
    response.headers[response.header_count] = .{ name = name, value = value };
    response.header_count += 1;
}

// Feed data to the incremental parser. Call after each read().
// Returns COMPLETE when a full request is ready in c.req.
// All parsed strings are zero-copy views into c.buf.
parse_request :: (c: *Connection) -> Parse_Result {
    // Parse request line: METHOD SP URI SP VERSION \r\n
    if c.parse_state == .REQUEST_LINE {
        // RFC 9112 §2.2: ignore empty lines received before the request line.
        while c.parse_offset + 1 < c.bytes_used && c.buf[c.parse_offset] == #char "\r" && c.buf[c.parse_offset + 1] == #char "\n" {
            c.parse_offset += 2;
        }
        crlf := find_crlf(c.buf.data, c.parse_offset, c.bytes_used);
        if crlf < 0 return .INCOMPLETE;

        line_start := c.parse_offset;

        // Find first space (end of method); the method is a non-empty token
        sp1 := find_byte(c.buf.data, line_start, crlf, #char " ");
        if sp1 <= line_start  return parse_fail(c, .MALFORMED);
        c.req.method = make_view(c.buf.data, line_start, sp1);
        if !is_token(c.req.method)  return parse_fail(c, .MALFORMED);

        // Find second space (end of the request target, which must not be empty)
        sp2 := find_byte(c.buf.data, sp1 + 1, crlf, #char " ");
        if sp2 <= sp1 + 1  return parse_fail(c, .MALFORMED);
        for i: sp1 + 1..sp2 - 1 {   // the target carries no control bytes (a bare CR or LF splits lines elsewhere)
            ch := c.buf[i];
            if ch < 0x21 || ch == 0x7F  return parse_fail(c, .MALFORMED);
        }

        // Split URI into path and query string at '?'
        qmark := find_byte(c.buf.data, sp1 + 1, sp2, #char "?");
        if qmark >= 0 {
            c.req.path = make_view(c.buf.data, sp1 + 1, qmark);
            c.req.query_string = make_view(c.buf.data, qmark + 1, sp2);
        } else {
            c.req.path = make_view(c.buf.data, sp1 + 1, sp2);
        }

        // Version is the rest of the line: exactly HTTP/1.x
        c.req.http_version = make_view(c.buf.data, sp2 + 1, crlf);
        version_error := check_http_version(c.req.http_version);
        if version_error != .NONE  return parse_fail(c, version_error);

        c.parse_offset = crlf + 2;
        c.parse_state = .HEADERS;
    }

    // Parse headers until empty line (\r\n\r\n)
    if c.parse_state == .HEADERS {
        while true {
            crlf := find_crlf(c.buf.data, c.parse_offset, c.bytes_used);
            if crlf < 0 return .INCOMPLETE;

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

            // Find colon separator. RFC 9112 §5.1: the field name is a token with no whitespace
            // before the colon; this also rejects obsolete line folding (§5.2), which starts with
            // SP or HTAB.
            colon := find_byte(c.buf.data, c.parse_offset, crlf, #char ":");
            if colon < 0  return parse_fail(c, .MALFORMED);
            name := make_view(c.buf.data, c.parse_offset, colon);
            if !is_token(name)  return parse_fail(c, .MALFORMED);

            // Dropping fields past the cap would silently lose framing headers (desync): refuse.
            if c.req.header_count >= MAX_HEADERS  return parse_fail(c, .TOO_MANY_HEADERS);

            // RFC 9110 §5.5: optional whitespace around the field value is not part of it, and the
            // value holds no CR, LF, NUL or other control byte. A bare LF kept here is a line break
            // to a front end that accepts LF line ends: a second, smuggled field.
            value := trim_ows(make_view(c.buf.data, colon + 1, crlf));
            if !is_field_value(value)  return parse_fail(c, .MALFORMED);
            c.req.headers[c.req.header_count] = .{ name = name, value = value };
            c.req.header_count += 1;

            c.parse_offset = crlf + 2;
        }
    }

    if c.parse_state == .CHUNKED  return parse_chunked(c);

    // Wait for request body bytes
    if c.parse_state == .BODY {
        body_available := c.bytes_used - c.parse_offset;
        if body_available >= c.req.content_length {
            c.req.body = make_view(c.buf.data, c.parse_offset, c.parse_offset + c.req.content_length);
            c.parse_offset += c.req.content_length;
            c.parse_state = .COMPLETE;
            return .COMPLETE;
        }
        return .INCOMPLETE;
    }

    if c.parse_state == .COMPLETE return .COMPLETE;
    return parse_fail(c, .MALFORMED);
}

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

// Clear every per-request field. The views point into the connection's read buffer, so a stale one
// would show the next request, or the next client on a recycled slot, bytes it never sent.
reset_request :: (req: *Request) {
    req.method         = "";
    req.path           = "";
    req.query_string   = "";
    req.http_version   = "";
    req.body           = "";
    req.header_count   = 0;
    req.keep_alive     = false;
    req.content_length = 0;
}

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

// Prepare connection for the next request (keep-alive pipelining).
// Shifts any remaining bytes to the start of the buffer.
reset_for_next_request :: (c: *Connection) {
    remaining := c.bytes_used - c.parse_offset;
    if remaining > 0  move_down(c.buf.data, 0, c.parse_offset, remaining);
    c.bytes_used = remaining;
    c.parse_offset = 0;
    reset_parse(c);
    c.request_start_ms = ifx remaining > 0 then now_ms() else 0;   // a pipelined next request is timed from now
}

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

Write_Result :: enum u8 #specified {
    SENT    :: 0;   // every byte reached the kernel
    PENDING :: 1;   // a tail is queued in c.pending; wait for EPOLLOUT
    ERROR   :: 2;   // the peer is gone or MAX_PENDING_BYTES was exceeded; the caller closes
}

// 1xx, 204 and 304 carry neither a body nor the body-describing headers (RFC 9110 §6.4.1, §8.6).
// 205 carries no content either (§15.3.6), but is framed with Content-Length: 0 (see below).
status_has_body :: inline (code: u16) -> bool {
    return code >= 200 && code != 204 && code != 205 && code != 304;
}

// Serialize the status line and headers from context.allocator, which the worker sets to the
// per-request Pool (reset after the write, blocks recycled). It must NOT use temporary storage:
// the original writer used `tprint`, which is hardwired to temp storage; under batch load the
// default 16 KB temp overflowed into repeated heap page allocations (~45% of CPU at high
// concurrency). `body_count` is what Content-Length reports; for HEAD that is the GET body's
// length even though no body is sent. An empty `date` omits the Date header.
build_response_header :: (req: *Request, response: *Response, date: string, body_count: s64) -> string {
    // Fast path for the overwhelmingly common shape: HTTP/1.1 keep-alive (no Connection header),
    // a status with a body, a Date, no custom headers. One sprint is measurably cheaper than the
    // builder below at high request rates (~3-4% at t32/c2000 on the 3970X, 2026-10-03).
    if response.header_count == 0 && date.count > 0 && req.keep_alive && status_has_body(response.status_code)
       && !string_equals(req.http_version, "HTTP/1.0") {
        return Basic.sprint("HTTP/1.1 % %\r\nDate: %\r\nContent-Type: %\r\nContent-Length: %\r\n\r\n",
            response.status_code, status_text(response.status_code), date, response.content_type, body_count);
    }

    builder: Basic.String_Builder;
    builder.allocator = context.allocator;
    Basic.print_to_builder(*builder, "HTTP/1.1 % %\r\n", response.status_code, status_text(response.status_code));
    if date.count > 0  Basic.print_to_builder(*builder, "Date: %\r\n", date);
    if status_has_body(response.status_code) {
        Basic.print_to_builder(*builder, "Content-Type: %\r\nContent-Length: %\r\n", response.content_type, body_count);
    } else if response.status_code == 205 {
        // Without a length a 205 would be framed by connection close (RFC 9112 §6.3).
        Basic.append(*builder, "Content-Length: 0\r\n");
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

// Serialize and write a response: one sendmsg of [header, body], so TCP_NODELAY never splits
// them into two packets, and MSG_NOSIGNAL so a client that reset the connection yields EPIPE
// instead of killing the process. What the kernel does not take is copied into c.pending (heap)
// before the caller resets the per-request Pool backing header and body. HEAD and bodiless
// statuses send the header only.
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
        // A failure to serve: the client receives a body shorter than its Content-Length.
        Basic.log_error("fd %: unsent response tail of % bytes exceeds MAX_PENDING_BYTES (%); closing", c.fd, unsent, MAX_PENDING_BYTES);
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

// Reply for a request the server refuses before a handler runs: status line, Date (when given;
// RFC 9110 §6.6.1 requires it on 4xx), Content-Length: 0, Connection: close. Built in temporary
// storage: refusals are rare, and write_or_queue copies any unsent tail to the heap.
canned_response :: (status: u16, date := "") -> string {
    if date.count > 0 {
        return Basic.tprint("HTTP/1.1 % %\r\nDate: %\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            status, status_text(status), date);
    }
    return Basic.tprint("HTTP/1.1 % %\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status, status_text(status));
}

// Send a small reply that must not be lost: what the kernel does not take is queued in c.pending
// (the caller then waits for EPOLLOUT). Requires an empty pending queue.
write_or_queue :: (c: *Connection, data: string) -> Write_Result {
    sent: s64 = 0;
    while true {
        n := send(c.fd, data.data, xx data.count, .NOSIGNAL);
        if n >= 0 { sent = n; break; }
        err := errno();
        if err == EINTR  continue;
        if err == EAGAIN || err == EWOULDBLOCK  break;
        if err == EPIPE  || err == ECONNRESET   return .ERROR;
        Basic.log_error("send failed on fd %: errno %", c.fd, err);
        return .ERROR;
    }
    if sent == data.count  return .SENT;
    if data.count - sent > MAX_PENDING_BYTES {
        Basic.log_error("fd %: unsent reply tail of % bytes exceeds MAX_PENDING_BYTES (%); closing", c.fd, data.count - sent, MAX_PENDING_BYTES);
        return .ERROR;
    }
    append_bytes(*c.pending, data.data + sent, data.count - sent);
    return .PENDING;
}

status_text :: (code: u16) -> string {
    if code == {
        case 100; return "Continue";
        case 101; return "Switching Protocols";
        case 200; return "OK";
        case 201; return "Created";
        case 204; return "No Content";
        case 205; return "Reset Content";
        case 206; return "Partial Content";
        case 301; return "Moved Permanently";
        case 302; return "Found";
        case 303; return "See Other";
        case 304; return "Not Modified";
        case 307; return "Temporary Redirect";
        case 308; return "Permanent Redirect";
        case 400; return "Bad Request";
        case 401; return "Unauthorized";
        case 403; return "Forbidden";
        case 404; return "Not Found";
        case 405; return "Method Not Allowed";
        case 408; return "Request Timeout";
        case 409; return "Conflict";
        case 413; return "Payload Too Large";
        case 414; return "URI Too Long";
        case 415; return "Unsupported Media Type";
        case 422; return "Unprocessable Entity";
        case 429; return "Too Many Requests";
        case 431; return "Request Header Fields Too Large";
        case 500; return "Internal Server Error";
        case 501; return "Not Implemented";
        case 502; return "Bad Gateway";
        case 503; return "Service Unavailable";
        case 504; return "Gateway Timeout";
        case 505; return "HTTP Version Not Supported";
        case; return "Unknown";
    }
}

// Content-based string comparison.
string_equals :: inline (a: string, b: string) -> bool {
    if a.count != b.count return false;
    for i: 0..a.count-1 {
        if a[i] != b[i] return false;
    }
    return true;
}

// Case-insensitive content-based string comparison.
string_equals_ci :: inline (a: string, b: string) -> bool {
    if a.count != b.count return false;
    for i: 0..a.count-1 {
        if to_lower(a[i]) != to_lower(b[i]) return false;
    }
    return true;
}

#scope_module

to_lower :: inline (ch: u8) -> u8 {
    if ch >= #char "A" && ch <= #char "Z" return ch + 32;
    return ch;
}

#scope_file

find_crlf :: inline (data: *u8, start: s64, end: s64) -> s64 {
    i := start;
    while i < end - 1 {
        if data[i] == #char "\r" && data[i + 1] == #char "\n" return i;
        i += 1;
    }
    return -1;
}

find_byte :: inline (data: *u8, start: s64, end: s64, byte: u8) -> s64 {
    i := start;
    while i < end {
        if data[i] == byte return i;
        i += 1;
    }
    return -1;
}

make_view :: inline (data: *u8, start: s64, end: s64) -> string {
    result: string;
    result.data = data + start;
    result.count = end - start;
    return result;
}

// Copy `count` bytes from buf+src down to buf+dst (dst <= src). Jai's memcpy is the LLVM
// intrinsic, undefined on overlap, and Basic has no memmove: memcpy only when the regions are
// disjoint, otherwise a forward byte copy, which is safe while the destination is below the source.
move_down :: (buf: *u8, dst: s64, src: s64, count: s64) {
    if count <= 0 || dst == src  return;
    if src - dst >= count  memcpy(buf + dst, buf + src, count);
    else                   for i: 0..count-1  buf[dst + i] = buf[src + i];
}

parse_fail :: inline (c: *Connection, e: Parse_Error) -> Parse_Result {
    c.parse_error = e;
    return .ERROR;
}

is_ows :: inline (ch: u8) -> bool {
    return ch == #char " " || ch == #char "\t";
}

trim_ows :: (s: string) -> string {
    r := s;
    while r.count > 0 && is_ows(r[0])            { r.data += 1; r.count -= 1; }
    while r.count > 0 && is_ows(r[r.count - 1])  r.count -= 1;
    return r;
}

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

// RFC 9112 §2.3: HTTP-version = "HTTP/" DIGIT "." DIGIT. Only major version 1 is served; a later
// minor version is handled as HTTP/1.1.
check_http_version :: (v: string) -> Parse_Error {
    if v.count != 8  return .MALFORMED;
    prefix := "HTTP/";
    for i: 0..prefix.count-1  if v[i] != prefix[i]  return .MALFORMED;
    if v[6] != #char "."  return .MALFORMED;
    if v[5] < #char "0" || v[5] > #char "9" || v[7] < #char "0" || v[7] > #char "9"  return .MALFORMED;
    if v[5] != #char "1"  return .VERSION_NOT_SUPPORTED;
    return .NONE;
}

// Content-Length = 1*DIGIT. More than 18 digits is far beyond any body this server accepts and
// could overflow s64; arithmetic_overflow_check is FATAL in every build, so such a value would kill
// the process. It is reported as too large without being computed.
parse_content_length :: (s: string) -> (value: s64, valid: bool, too_large: bool) {
    if s.count == 0  return 0, false, false;
    for i: 0..s.count-1  if s[i] < #char "0" || s[i] > #char "9"  return 0, false, false;
    first := 0;   // leading zeros are legal and carry no magnitude
    while first < s.count - 1 && s[first] == #char "0"  first += 1;
    if s.count - first > 18  return 0, true, true;
    result: s64 = 0;
    for i: first..s.count-1  result = result * 10 + cast(s64) (s[i] - #char "0");
    return result, true, false;
}

// RFC 9110 §5.5: field-value bytes are VCHAR, SP, HTAB or obs-text; no CR, LF, NUL or other CTL.
is_field_value :: (s: string) -> bool {
    for i: 0..s.count-1 {
        ch := s[i];
        if (ch < 0x20 && ch != #char "\t") || ch == 0x7F  return false;
    }
    return true;
}

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

// RFC 9112 §3.2 / RFC 3986 §3.2: Host = uri-host [ ":" port ]. Checked as a character set:
// unreserved, pct-encoded, sub-delims, ':' and the brackets of an IP literal. Empty is legal.
is_host_value :: (s: string) -> bool {
    HOST_PUNCTUATION :: "-._~%!$&'()*+,;=:[]";
    for i: 0..s.count-1 {
        ch := s[i];
        if (ch >= #char "a" && ch <= #char "z") || (ch >= #char "A" && ch <= #char "Z") || (ch >= #char "0" && ch <= #char "9")  continue;
        is_punct := false;
        for p: 0..HOST_PUNCTUATION.count-1  if ch == HOST_PUNCTUATION[p] { is_punct = true; break; }
        if !is_punct  return false;
    }
    return true;
}

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

// HTTP/1.1 (and any later 1.x) defaults to keep-alive, HTTP/1.0 to close. Every Connection field is
// a comma-separated option list (RFC 9110 §7.6.1); `close` wins over `keep-alive`.
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
