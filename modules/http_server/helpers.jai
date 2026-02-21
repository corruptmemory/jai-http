
// -- Response helpers --

json :: (resp: *Response, body: string) {
    resp.content_type = "application/json";
    resp.body = body;
}

text :: (resp: *Response, body: string) {
    resp.content_type = "text/plain";
    resp.body = body;
}

html :: (resp: *Response, body: string) {
    resp.content_type = "text/html";
    resp.body = body;
}

redirect :: (resp: *Response, url: string, code: u16 = 302) {
    resp.status_code = code;
    set_header(resp, "Location", url);
    resp.body = "";
}

// -- URL decoding --

// Decode a percent-encoded string. If no encoding is present, returns the original
// string (zero-copy). Otherwise allocates from context allocator (per-request pool).
url_decode :: (s: string) -> string {
    // Fast path: check if decoding is needed
    needs_decode := false;
    for i: 0..s.count - 1 {
        if s[i] == #char "%" || s[i] == #char "+" {
            needs_decode = true;
            break;
        }
    }
    if !needs_decode return s;

    // Decoded length is always <= original length
    buf := cast(*u8) Basic.alloc(s.count);
    wi := 0;  // write index
    ri := 0;  // read index

    while ri < s.count {
        ch := s[ri];
        if ch == #char "%" && ri + 2 < s.count {
            hi := hex_digit(s[ri + 1]);
            lo := hex_digit(s[ri + 2]);
            if hi >= 0 && lo >= 0 {
                buf[wi] = cast(u8)(hi << 4 | lo);
                wi += 1;
                ri += 3;
                continue;
            }
        }
        if ch == #char "+" {
            buf[wi] = #char " ";
        } else {
            buf[wi] = ch;
        }
        wi += 1;
        ri += 1;
    }

    result: string;
    result.data = buf;
    result.count = wi;
    return result;
}

// -- Query parameter access --

// Look up a query parameter by name from the request's query string.
// Returns the URL-decoded value. Allocates from context allocator only if decoding is needed.
query_param :: (req: *Request, name: string) -> (value: string, found: bool) {
    qs := req.query_string;
    if qs.count == 0 {
        result: string;
        return result, false;
    }

    pos := 0;
    while pos < qs.count {
        // Find end of this key=value pair
        amp := pos;
        while amp < qs.count && qs[amp] != #char "&" {
            amp += 1;
        }

        // Find '=' within this pair
        eq := pos;
        while eq < amp && qs[eq] != #char "=" {
            eq += 1;
        }

        key: string;
        key.data = qs.data + pos;
        key.count = eq - pos;

        decoded_key := url_decode(key);
        if string_equals(decoded_key, name) {
            if eq < amp {
                val: string;
                val.data = qs.data + eq + 1;
                val.count = amp - eq - 1;
                return url_decode(val), true;
            } else {
                // Key with no value (e.g. "?flag")
                result: string;
                return result, true;
            }
        }

        pos = amp + 1;
    }

    result: string;
    return result, false;
}

// -- Form parsing (application/x-www-form-urlencoded) --

Form_Value :: struct {
    name:  string;
    value: string;
}

Form_Data :: struct {
    values: [MAX_FORM_VALUES] Form_Value;
    count:  s32;
}

// Parse a URL-encoded form body. Values are URL-decoded (allocated from context allocator if needed).
parse_form :: (req: *Request) -> Form_Data {
    form: Form_Data;
    body := req.body;
    if body.count == 0 return form;

    pos := 0;
    while pos < body.count && form.count < MAX_FORM_VALUES {
        // Find end of this key=value pair
        amp := pos;
        while amp < body.count && body[amp] != #char "&" {
            amp += 1;
        }

        // Find '=' within this pair
        eq := pos;
        while eq < amp && body[eq] != #char "=" {
            eq += 1;
        }

        fv := *form.values[form.count];

        key: string;
        key.data = body.data + pos;
        key.count = eq - pos;
        fv.name = url_decode(key);

        if eq < amp {
            val: string;
            val.data = body.data + eq + 1;
            val.count = amp - eq - 1;
            fv.value = url_decode(val);
        }

        form.count += 1;
        pos = amp + 1;
    }

    return form;
}

// Look up a form value by name.
form_value :: (form: *Form_Data, name: string) -> (value: string, found: bool) {
    for i: 0..cast(s64) form.count - 1 {
        if string_equals(form.values[i].name, name) {
            return form.values[i].value, true;
        }
    }
    result: string;
    return result, false;
}

// -- Multipart parsing (multipart/form-data) --

Multipart_Part :: struct {
    name:         string;
    filename:     string;
    content_type: string;
    body:         string;
}

Multipart_Data :: struct {
    parts: [MAX_MULTIPART_PARTS] Multipart_Part;
    count: s32;
}

// Parse a multipart/form-data body. Returns the parsed data and true on success.
// All strings are zero-copy views into the request body buffer.
parse_multipart :: (req: *Request) -> (data: Multipart_Data, ok: bool) {
    data: Multipart_Data;

    // Extract boundary from Content-Type header
    ct, has_ct := get_header(req, "Content-Type");
    if !has_ct {
        return data, false;
    }

    boundary := extract_boundary(ct);
    if boundary.count == 0 {
        return data, false;
    }

    body := req.body;
    if body.count == 0 return data, false;

    // Each part is delimited by --boundary\r\n
    // Final delimiter is --boundary--
    // Build the delimiter strings
    delim_prefix := "--";

    pos := 0;

    // Skip preamble: find first --boundary\r\n
    pos = find_boundary(body, pos, delim_prefix, boundary);
    if pos < 0 return data, false;

    // Skip past --boundary\r\n
    pos += 2 + boundary.count;
    if pos + 2 <= body.count && body[pos] == #char "-" && body[pos + 1] == #char "-" {
        // Immediate close: --boundary-- (empty body)
        return data, true;
    }
    if pos + 2 <= body.count && body[pos] == #char "\r" && body[pos + 1] == #char "\n" {
        pos += 2;
    } else {
        return data, false;
    }

    while pos < body.count && data.count < MAX_MULTIPART_PARTS {
        part := *data.parts[data.count];

        // Parse part headers until \r\n\r\n
        headers_end := find_empty_line(body, pos);
        if headers_end < 0 return data, false;

        // Parse headers within this part.
        // headers_end points to the first \r of \r\n\r\n. The last header's
        // \r\n is at headers_end, so we search up to headers_end + 2.
        hpos := pos;
        while hpos < headers_end {
            line_end := find_crlf_in(body, hpos, headers_end + 2);
            if line_end < 0 break;

            line: string;
            line.data = body.data + hpos;
            line.count = line_end - hpos;

            if starts_with_ci(line, "Content-Disposition:") {
                parse_content_disposition(line, part);
            } else if starts_with_ci(line, "Content-Type:") {
                // Skip "Content-Type:" and whitespace
                ct_start := 13;  // len("Content-Type:")
                while ct_start < line.count && line[ct_start] == #char " " {
                    ct_start += 1;
                }
                part.content_type.data = line.data + ct_start;
                part.content_type.count = line.count - ct_start;
            }

            hpos = line_end + 2;  // skip \r\n
        }

        // Body starts after \r\n\r\n
        body_start := headers_end + 4;

        // Find next boundary
        next_boundary := find_boundary(body, body_start, delim_prefix, boundary);
        if next_boundary < 0 return data, false;

        // Body ends before \r\n--boundary
        body_end := next_boundary - 2;  // strip trailing \r\n before boundary
        if body_end < body_start  body_end = body_start;

        part.body.data = body.data + body_start;
        part.body.count = body_end - body_start;

        data.count += 1;

        // Advance past --boundary
        pos = next_boundary + 2 + boundary.count;

        // Check for closing --boundary-- vs --boundary\r\n
        if pos + 2 <= body.count && body[pos] == #char "-" && body[pos + 1] == #char "-" {
            break;  // End of multipart
        }
        if pos + 2 <= body.count && body[pos] == #char "\r" && body[pos + 1] == #char "\n" {
            pos += 2;
        } else {
            break;
        }
    }

    return data, true;
}

// Look up a multipart part by field name.
multipart_value :: (data: *Multipart_Data, name: string) -> *Multipart_Part {
    for i: 0..cast(s64) data.count - 1 {
        if string_equals(data.parts[i].name, name) {
            return *data.parts[i];
        }
    }
    return null;
}

// -- Private helpers --

#scope_file

hex_digit :: inline (ch: u8) -> s32 {
    if ch >= #char "0" && ch <= #char "9" return cast(s32)(ch - #char "0");
    if ch >= #char "a" && ch <= #char "f" return cast(s32)(ch - #char "a" + 10);
    if ch >= #char "A" && ch <= #char "F" return cast(s32)(ch - #char "A" + 10);
    return -1;
}

// Find \r\n within a range
find_crlf_in :: (s: string, start: s64, end: s64) -> s64 {
    i := start;
    while i < end - 1 {
        if s[i] == #char "\r" && s[i + 1] == #char "\n" return i;
        i += 1;
    }
    return -1;
}

// Find \r\n\r\n starting from pos
find_empty_line :: (s: string, pos: s64) -> s64 {
    i := pos;
    while i < s.count - 3 {
        if s[i] == #char "\r" && s[i+1] == #char "\n" && s[i+2] == #char "\r" && s[i+3] == #char "\n" {
            return i;
        }
        i += 1;
    }
    return -1;
}

// Find --boundary starting from pos
find_boundary :: (s: string, pos: s64, prefix: string, boundary: string) -> s64 {
    needle_len := 2 + boundary.count;  // "--" + boundary
    i := pos;
    while i <= s.count - needle_len {
        if s[i] == #char "-" && s[i+1] == #char "-" {
            // Check if boundary matches
            match := true;
            for k: 0..boundary.count - 1 {
                if s[i + 2 + k] != boundary[k] {
                    match = false;
                    break;
                }
            }
            if match return i;
        }
        i += 1;
    }
    return -1;
}

// Extract boundary from Content-Type header value.
// e.g. "multipart/form-data; boundary=----abc" -> "----abc"
extract_boundary :: (ct: string) -> string {
    target :: "boundary=";
    i := 0;
    while i <= ct.count - target.count {
        match := true;
        for k: 0..target.count - 1 {
            if to_lower(ct[i + k]) != target[k] {
                match = false;
                break;
            }
        }
        if match {
            start := i + target.count;
            end := start;
            // Boundary may be quoted
            if start < ct.count && ct[start] == #char "\"" {
                start += 1;
                end = start;
                while end < ct.count && ct[end] != #char "\"" {
                    end += 1;
                }
            } else {
                while end < ct.count && ct[end] != #char ";" && ct[end] != #char " " && ct[end] != #char "\r" {
                    end += 1;
                }
            }
            result: string;
            result.data = ct.data + start;
            result.count = end - start;
            return result;
        }
        i += 1;
    }
    result: string;
    return result;
}

// Case-insensitive starts-with check.
starts_with_ci :: (s: string, prefix: string) -> bool {
    if s.count < prefix.count return false;
    for i: 0..prefix.count - 1 {
        if to_lower(s[i]) != to_lower(prefix[i]) return false;
    }
    return true;
}

// Parse Content-Disposition header to extract name and filename.
// e.g. 'Content-Disposition: form-data; name="field"; filename="file.txt"'
parse_content_disposition :: (line: string, part: *Multipart_Part) {
    // Find name="..."
    part.name = extract_quoted_param(line, "name=");
    part.filename = extract_quoted_param(line, "filename=");
}

// Extract a quoted parameter value from a header line.
// Looks for 'key="value"' and returns value.
extract_quoted_param :: (line: string, key: string) -> string {
    i := 0;
    while i <= line.count - key.count {
        match := true;
        for k: 0..key.count - 1 {
            if to_lower(line[i + k]) != to_lower(key[k]) {
                match = false;
                break;
            }
        }
        if match {
            start := i + key.count;
            if start < line.count && line[start] == #char "\"" {
                start += 1;
                end := start;
                while end < line.count && line[end] != #char "\"" {
                    end += 1;
                }
                result: string;
                result.data = line.data + start;
                result.count = end - start;
                return result;
            } else {
                // Unquoted value — read until ; or space or end
                end := start;
                while end < line.count && line[end] != #char ";" && line[end] != #char " " {
                    end += 1;
                }
                result: string;
                result.data = line.data + start;
                result.count = end - start;
                return result;
            }
        }
        i += 1;
    }
    result: string;
    return result;
}
