
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
    BODY         :: 2;
    COMPLETE     :: 3;
    ERROR        :: 4;
}

Parse_Result :: enum u8 #specified {
    INCOMPLETE :: 0;
    COMPLETE   :: 1;
    ERROR      :: 2;
}

// Why parse_request returned .ERROR; decides the canned reply (400 vs 413).
Parse_Error :: enum u8 #specified {
    NONE           :: 0;
    MALFORMED      :: 1;
    BODY_TOO_LARGE :: 2;
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
        crlf := find_crlf(c.buf.data, c.parse_offset, c.bytes_used);
        if crlf < 0 return .INCOMPLETE;

        line_start := c.parse_offset;

        // Find first space (end of method)
        sp1 := find_byte(c.buf.data, line_start, crlf, #char " ");
        if sp1 < 0 return .ERROR;
        c.req.method = make_view(c.buf.data, line_start, sp1);

        // Find second space (end of URI)
        sp2 := find_byte(c.buf.data, sp1 + 1, crlf, #char " ");
        if sp2 < 0 return .ERROR;

        // Split URI into path and query string at '?'
        qmark := find_byte(c.buf.data, sp1 + 1, sp2, #char "?");
        if qmark >= 0 {
            c.req.path = make_view(c.buf.data, sp1 + 1, qmark);
            c.req.query_string = make_view(c.buf.data, qmark + 1, sp2);
        } else {
            c.req.path = make_view(c.buf.data, sp1 + 1, sp2);
        }

        // Version is the rest of the line
        c.req.http_version = make_view(c.buf.data, sp2 + 1, crlf);

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
                determine_keep_alive(*c.req);

                // Check for request body via Content-Length
                cl_str, has_cl := get_header(*c.req, "Content-Length");
                if has_cl {
                    cl := parse_s64(cl_str);
                    if cl < 0 return .ERROR;
                    if cl > 0 {
                        max_body := cast(s64) READ_BUFFER_SIZE - c.parse_offset;
                        if cl > max_body return .ERROR;  // Body won't fit in buffer
                        c.req.content_length = cl;
                        c.parse_state = .BODY;
                        break;  // Fall through to BODY check below
                    }
                }

                c.parse_state = .COMPLETE;
                return .COMPLETE;
            }

            // Find colon separator
            colon := find_byte(c.buf.data, c.parse_offset, crlf, #char ":");
            if colon < 0 return .ERROR;

            if c.req.header_count < MAX_HEADERS {
                // Skip colon and leading whitespace before the value
                val_start := colon + 1;
                while val_start < crlf && c.buf[val_start] == #char " " {
                    val_start += 1;
                }
                c.req.headers[c.req.header_count] = .{
                    name  = make_view(c.buf.data, c.parse_offset, colon),
                    value = make_view(c.buf.data, val_start, crlf),
                };
                c.req.header_count += 1;
            }

            c.parse_offset = crlf + 2;
        }
    }

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
    return .ERROR;
}

// Prepare connection for the next request (keep-alive pipelining).
// Shifts any remaining bytes to the start of the buffer.
reset_for_next_request :: (c: *Connection) {
    remaining := c.bytes_used - c.parse_offset;
    if remaining > 0 && c.parse_offset > 0 {
        // Copy forward (safe: destination < source)
        for i: 0..remaining-1 {
            c.buf[i] = c.buf[c.parse_offset + i];
        }
    }
    c.bytes_used = remaining;
    c.parse_offset = 0;
    c.parse_state = .REQUEST_LINE;
    c.req.header_count = 0;
    c.req.keep_alive = false;
    c.req.content_length = 0;
}

Write_Result :: enum u8 #specified {
    SENT    :: 0;   // every byte reached the kernel
    PENDING :: 1;   // a tail is queued in c.pending; wait for EPOLLOUT
    ERROR   :: 2;   // the peer is gone or MAX_PENDING_BYTES was exceeded; the caller closes
}

// 1xx, 204 and 304 carry neither a body nor the body-describing headers (RFC 9110 §6.4.1, §8.6).
status_has_body :: inline (code: u16) -> bool {
    return code >= 200 && code != 204 && code != 304;
}

// Serialize the status line and headers from context.allocator, which the worker sets to the
// per-request Pool (reset after the write, blocks recycled). It must NOT use temporary storage:
// the original writer used `tprint`, which is hardwired to temp storage; under batch load the
// default 16 KB temp overflowed into repeated heap page allocations (~45% of CPU at high
// concurrency). `body_count` is what Content-Length reports; for HEAD that is the GET body's
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

status_text :: (code: u16) -> string {
    if code == {
        case 200; return "OK";
        case 201; return "Created";
        case 204; return "No Content";
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
        case 415; return "Unsupported Media Type";
        case 422; return "Unprocessable Entity";
        case 429; return "Too Many Requests";
        case 431; return "Request Header Fields Too Large";
        case 500; return "Internal Server Error";
        case 502; return "Bad Gateway";
        case 503; return "Service Unavailable";
        case 504; return "Gateway Timeout";
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

parse_s64 :: (s: string) -> s64 {
    if s.count == 0 return -1;
    result: s64 = 0;
    for i: 0..s.count-1 {
        ch := s[i];
        if ch < #char "0" || ch > #char "9" return -1;
        result = result * 10 + cast(s64)(ch - #char "0");
    }
    return result;
}

// Set keep_alive based on HTTP version and Connection header.
determine_keep_alive :: (req: *Request) {
    // HTTP/1.1 defaults to keep-alive; HTTP/1.0 defaults to close
    req.keep_alive = string_equals(req.http_version, "HTTP/1.1");

    // Override with Connection header
    for i: 0..cast(s64) req.header_count - 1 {
        if string_equals_ci(req.headers[i].name, "Connection") {
            if string_equals_ci(req.headers[i].value, "close") {
                req.keep_alive = false;
            } else if string_equals_ci(req.headers[i].value, "keep-alive") {
                req.keep_alive = true;
            }
            break;
        }
    }
}
