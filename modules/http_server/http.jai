
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
    h := *response.headers[response.header_count];
    h.name = name;
    h.value = value;
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
                h := *c.req.headers[c.req.header_count];
                h.name = make_view(c.buf.data, c.parse_offset, colon);

                // Skip colon and leading whitespace
                val_start := colon + 1;
                while val_start < crlf && c.buf[val_start] == #char " " {
                    val_start += 1;
                }
                h.value = make_view(c.buf.data, val_start, crlf);
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

// Serialize and write a response to the fd.
// Uses writev() to send headers + body in a single syscall so TCP_NODELAY
// does not split them into two packets.
write_response :: (fd: s32, response: *Response, keep_alive: bool) {
    conn_str := ifx keep_alive then "keep-alive" else "close";

    header: string;
    if response.header_count == 0 {
        // Fast path: no custom headers — one tprint, no loop
        header = Basic.tprint("HTTP/1.1 % %\r\nContent-Type: %\r\nContent-Length: %\r\nConnection: %\r\n\r\n",
            response.status_code, status_text(response.status_code),
            response.content_type, response.body.count, conn_str);
    } else {
        // Slow path: build all headers into a single temp buffer first
        builder: Basic.String_Builder;
        builder.allocator = Basic.temp;
        Basic.print_to_builder(*builder, "HTTP/1.1 % %\r\nContent-Type: %\r\nContent-Length: %\r\nConnection: %\r\n",
            response.status_code, status_text(response.status_code),
            response.content_type, response.body.count, conn_str);
        for i: 0..cast(s64) response.header_count - 1 {
            Basic.print_to_builder(*builder, "%: %\r\n", response.headers[i].name, response.headers[i].value);
        }
        Basic.append(*builder, "\r\n");
        header = Basic.builder_to_string(*builder,, allocator = Basic.temp);
    }

    if response.body.count > 0 {
        iov: [2] iovec;
        iov[0].iov_base = cast(*void) header.data;
        iov[0].iov_len  = xx header.count;
        iov[1].iov_base = cast(*void) response.body.data;
        iov[1].iov_len  = xx response.body.count;
        writev(fd, iov.data, 2);
    } else {
        send_all(fd, header.data, header.count);
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
        case 409; return "Conflict";
        case 413; return "Payload Too Large";
        case 415; return "Unsupported Media Type";
        case 422; return "Unprocessable Entity";
        case 429; return "Too Many Requests";
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

send_all :: (fd: s32, data: *u8, count: s64) {
    remaining := count;
    offset: s64 = 0;
    while remaining > 0 {
        bytes_sent := write(fd, data + offset, xx remaining);
        if bytes_sent < 0 {
            err := errno();
            if err == EINTR continue;
            break;
        }
        remaining -= bytes_sent;
        offset += bytes_sent;
    }
}
