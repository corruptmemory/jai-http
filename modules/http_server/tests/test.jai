
// -- Connection struct tests --

test_connection_struct :: () {
    c: Connection;
    assert(c.state == .FREE, "New connection should be FREE, got %", c.state);
    assert(c.fd == -1, "New connection fd should be -1, got %", c.fd);
    assert(c.instance == 0, "New connection instance should be 0, got %", c.instance);
    assert(c.next_free == null, "New connection next_free should be null");
    assert(c.bytes_used == 0, "New connection bytes_used should be 0");
    assert(c.parse_state == .REQUEST_LINE, "New connection parse_state should be REQUEST_LINE");
    print("  PASS: test_connection_struct\n");
}

// -- Connection pool tests --

test_pool_init :: () {
    pool: Connection_Pool;
    init_pool(*pool, 4);
    defer destroy_pool(*pool);

    assert(pool.total == 4, "Pool total should be 4, got %", pool.total);
    assert(pool.free_count == 4, "Pool free_count should be 4, got %", pool.free_count);
    assert(pool.free_list != null, "Free list should not be null");

    // Walk the free list — should have exactly 4 entries
    count := 0;
    c := pool.free_list;
    while c != null {
        assert(c.state == .FREE, "Free list entry should be FREE");
        assert(c.fd == -1, "Free list entry fd should be -1");
        c = c.next_free;
        count += 1;
    }
    assert(count == 4, "Free list should have 4 entries, got %", count);

    print("  PASS: test_pool_init\n");
}

test_pool_get_connection :: () {
    pool: Connection_Pool;
    init_pool(*pool, 4);
    defer destroy_pool(*pool);

    c := get_connection(*pool);
    assert(c != null, "get_connection should return non-null");
    assert(c.state == .ACTIVE, "Connection should be ACTIVE after get");
    assert(c.instance == 1, "Instance should be 1 after first get (flipped from 0)");
    assert(pool.free_count == 3, "Free count should be 3 after one get");

    print("  PASS: test_pool_get_connection\n");
}

test_pool_exhaust :: () {
    pool: Connection_Pool;
    init_pool(*pool, 3);
    defer destroy_pool(*pool);

    conns: [3] *Connection;
    for * conns {
        it.* = get_connection(*pool);
        assert(it.* != null, "Should get connection %", it_index);
    }

    assert(pool.free_count == 0, "Pool should be empty");
    extra := get_connection(*pool);
    assert(extra == null, "Should return null when pool exhausted");

    print("  PASS: test_pool_exhaust\n");
}

test_pool_free_and_reuse :: () {
    pool: Connection_Pool;
    init_pool(*pool, 2);
    defer destroy_pool(*pool);

    c1 := get_connection(*pool);
    c2 := get_connection(*pool);
    assert(pool.free_count == 0);

    // Free c1
    free_connection(*pool, c1);
    assert(pool.free_count == 1);
    assert(c1.state == .FREE);
    assert(c1.fd == -1);

    // Re-get — should get c1 back (LIFO)
    c3 := get_connection(*pool);
    assert(c3 == c1, "Should reuse freed connection");
    assert(c3.state == .ACTIVE);
    assert(c3.instance == 0, "Instance should flip back to 0, got %", c3.instance);

    print("  PASS: test_pool_free_and_reuse\n");
}

test_pool_instance_bit :: () {
    pool: Connection_Pool;
    init_pool(*pool, 1);
    defer destroy_pool(*pool);

    c := get_connection(*pool);
    assert(c.instance == 1, "First get: instance should be 1");

    free_connection(*pool, c);
    c = get_connection(*pool);
    assert(c.instance == 0, "Second get: instance should be 0");

    free_connection(*pool, c);
    c = get_connection(*pool);
    assert(c.instance == 1, "Third get: instance should be 1");

    print("  PASS: test_pool_instance_bit\n");
}

test_pool_connections_are_distinct :: () {
    pool: Connection_Pool;
    init_pool(*pool, 4);
    defer destroy_pool(*pool);

    c1 := get_connection(*pool);
    c2 := get_connection(*pool);
    c3 := get_connection(*pool);
    c4 := get_connection(*pool);

    // All should be distinct pointers
    assert(c1 != c2);
    assert(c1 != c3);
    assert(c1 != c4);
    assert(c2 != c3);
    assert(c2 != c4);
    assert(c3 != c4);

    print("  PASS: test_pool_connections_are_distinct\n");
}

// -- Event engine tests (encode/decode/stale, no actual sockets needed) --

test_encode_decode_connection_ptr :: () {
    pool: Connection_Pool;
    init_pool(*pool, 2);
    defer destroy_pool(*pool);

    c := get_connection(*pool);
    assert(c.instance == 1);

    // Encode and decode round-trip
    encoded := encode_connection_ptr(c);
    decoded_c, decoded_instance := decode_connection_ptr(encoded);
    assert(decoded_c == c, "Decoded connection should match original");
    assert(decoded_instance == 1, "Decoded instance should be 1, got %", decoded_instance);

    // After free+reget, instance flips — encoding changes
    free_connection(*pool, c);
    c = get_connection(*pool);
    assert(c.instance == 0);

    encoded2 := encode_connection_ptr(c);
    decoded_c2, decoded_instance2 := decode_connection_ptr(encoded2);
    assert(decoded_c2 == c, "Decoded connection should still match");
    assert(decoded_instance2 == 0, "Decoded instance should be 0 after flip");

    print("  PASS: test_encode_decode_connection_ptr\n");
}

test_stale_event_detection :: () {
    pool: Connection_Pool;
    init_pool(*pool, 1);
    defer destroy_pool(*pool);

    c := get_connection(*pool);
    assert(c.instance == 1);

    // Simulate: event was registered with current instance
    old_encoded := encode_connection_ptr(c);

    // Connection recycled: free + reget flips instance
    free_connection(*pool, c);
    c = get_connection(*pool);
    assert(c.instance == 0);

    // Old event should now be detected as stale
    assert(is_stale_event(old_encoded, c) == true, "Old event should be stale after recycle");

    // New event with current instance should not be stale
    new_encoded := encode_connection_ptr(c);
    assert(is_stale_event(new_encoded, c) == false, "Current event should not be stale");

    print("  PASS: test_stale_event_detection\n");
}

test_event_engine_init_destroy :: () {
    engine: Event_Engine;
    ok := init_event_engine(*engine);
    assert(ok, "Event engine init should succeed");
    assert(engine.epoll_fd >= 0, "epoll_fd should be valid, got %", engine.epoll_fd);

    destroy_event_engine(*engine);
    assert(engine.epoll_fd == -1, "epoll_fd should be -1 after destroy");

    print("  PASS: test_event_engine_init_destroy\n");
}

// -- HTTP parser tests --

fill_request :: (c: *Connection, raw: string) {
    memcpy(c.buf.data, raw.data, raw.count);
    c.bytes_used = raw.count;
    c.parse_offset = 0;
    c.parse_state = .REQUEST_LINE;
    c.req.header_count = 0;
    c.req.keep_alive = false;
}

test_parse_simple_get :: () {
    c: Connection;
    fill_request(*c, "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n");

    result := parse_request(*c);
    assert(result == .COMPLETE, "Should parse completely");
    assert(string_equals(c.req.method, "GET"), "Method should be GET");
    assert(string_equals(c.req.path, "/hello"), "Path should be /hello");
    assert(string_equals(c.req.http_version, "HTTP/1.1"), "Version should be HTTP/1.1");
    assert(c.req.header_count == 1, "Should have 1 header, got %", c.req.header_count);
    assert(string_equals_ci(c.req.headers[0].name, "Host"), "Header name should be Host");
    assert(string_equals(c.req.headers[0].value, "localhost"), "Header value should be localhost");
    assert(c.req.keep_alive == true, "HTTP/1.1 should default to keep-alive");

    print("  PASS: test_parse_simple_get\n");
}

test_parse_multiple_headers :: () {
    c: Connection;
    fill_request(*c, "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n");

    result := parse_request(*c);
    assert(result == .COMPLETE, "Should parse completely");
    assert(string_equals(c.req.method, "POST"), "Method should be POST");
    assert(string_equals(c.req.path, "/submit"), "Path should be /submit");
    assert(c.req.header_count == 3, "Should have 3 headers, got %", c.req.header_count);
    assert(string_equals_ci(c.req.headers[0].name, "Host"));
    assert(string_equals(c.req.headers[0].value, "example.com"));
    assert(string_equals_ci(c.req.headers[1].name, "Content-Type"));
    assert(string_equals(c.req.headers[1].value, "application/json"));
    assert(string_equals_ci(c.req.headers[2].name, "Content-Length"));
    assert(string_equals(c.req.headers[2].value, "0"));

    print("  PASS: test_parse_multiple_headers\n");
}

test_parse_incomplete :: () {
    c: Connection;
    // Request line without \r\n\r\n — incomplete
    fill_request(*c, "GET / HTTP/1.1\r\nHost: localhost\r\n");

    result := parse_request(*c);
    assert(result == .INCOMPLETE, "Should be incomplete without final \\r\\n");
    assert(c.parse_state == .HEADERS, "Should be in HEADERS state");

    print("  PASS: test_parse_incomplete\n");
}

test_parse_incremental :: () {
    c: Connection;
    // First chunk: partial request
    chunk1 := "GET / HTTP/1.1\r\nHos";
    memcpy(c.buf.data, chunk1.data, chunk1.count);
    c.bytes_used = chunk1.count;

    result := parse_request(*c);
    assert(result == .INCOMPLETE, "First chunk should be incomplete");

    // Second chunk: rest of request
    chunk2 := "t: localhost\r\n\r\n";
    memcpy(c.buf.data + c.bytes_used, chunk2.data, chunk2.count);
    c.bytes_used += chunk2.count;

    result = parse_request(*c);
    assert(result == .COMPLETE, "Should complete after second chunk");
    assert(string_equals(c.req.method, "GET"));
    assert(string_equals(c.req.path, "/"));
    assert(c.req.header_count == 1);
    assert(string_equals(c.req.headers[0].value, "localhost"));

    print("  PASS: test_parse_incremental\n");
}

test_keepalive_http11_default :: () {
    c: Connection;
    fill_request(*c, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(c.req.keep_alive == true, "HTTP/1.1 should default to keep-alive");
    print("  PASS: test_keepalive_http11_default\n");
}

test_keepalive_http10_default :: () {
    c: Connection;
    fill_request(*c, "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(c.req.keep_alive == false, "HTTP/1.0 should default to close");
    print("  PASS: test_keepalive_http10_default\n");
}

test_keepalive_http11_explicit_close :: () {
    c: Connection;
    fill_request(*c, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(c.req.keep_alive == false, "HTTP/1.1 with Connection: close should close");
    print("  PASS: test_keepalive_http11_explicit_close\n");
}

test_keepalive_http10_explicit_keepalive :: () {
    c: Connection;
    fill_request(*c, "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(c.req.keep_alive == true, "HTTP/1.0 with Connection: keep-alive should keep alive");
    print("  PASS: test_keepalive_http10_explicit_keepalive\n");
}

test_keepalive_case_insensitive :: () {
    c: Connection;
    fill_request(*c, "GET / HTTP/1.1\r\nHost: localhost\r\nconnection: Close\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(c.req.keep_alive == false, "Case-insensitive Connection: Close should close");
    print("  PASS: test_keepalive_case_insensitive\n");
}

// -- Header helper tests --

test_get_header :: () {
    c: Connection;
    fill_request(*c, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Custom: hello\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);

    val, found := get_header(*c.req, "Host");
    assert(found, "Should find Host header");
    assert(string_equals(val, "example.com"), "Host should be example.com");

    val2, found2 := get_header(*c.req, "X-Custom");
    assert(found2, "Should find X-Custom header");
    assert(string_equals(val2, "hello"), "X-Custom should be hello");

    // Case-insensitive lookup
    val3, found3 := get_header(*c.req, "host");
    assert(found3, "Should find host (lowercase)");
    assert(string_equals(val3, "example.com"));

    // Missing header
    _, found4 := get_header(*c.req, "X-Missing");
    assert(!found4, "Should not find X-Missing");

    print("  PASS: test_get_header\n");
}

test_set_header :: () {
    resp: Response;
    set_header(*resp, "X-Request-Id", "abc123");
    assert(resp.header_count == 1, "Should have 1 custom header");
    assert(string_equals(resp.headers[0].name, "X-Request-Id"));
    assert(string_equals(resp.headers[0].value, "abc123"));

    set_header(*resp, "X-Another", "value2");
    assert(resp.header_count == 2, "Should have 2 custom headers");

    print("  PASS: test_set_header\n");
}

// -- Query string tests --

test_parse_query_string :: () {
    c: Connection;
    fill_request(*c, "GET /search?q=hello&lang=en HTTP/1.1\r\nHost: localhost\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(string_equals(c.req.path, "/search"), "Path should be /search, got '%'", c.req.path);
    assert(string_equals(c.req.query_string, "q=hello&lang=en"), "Query string should be q=hello&lang=en, got '%'", c.req.query_string);

    print("  PASS: test_parse_query_string\n");
}

test_parse_no_query_string :: () {
    c: Connection;
    fill_request(*c, "GET /plain HTTP/1.1\r\nHost: localhost\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(string_equals(c.req.path, "/plain"), "Path should be /plain");
    assert(c.req.query_string.count == 0, "Query string should be empty");

    print("  PASS: test_parse_no_query_string\n");
}

// -- Request body tests --

test_parse_body :: () {
    c: Connection;
    fill_request(*c, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\nHello, World!");
    result := parse_request(*c);
    assert(result == .COMPLETE, "Should parse completely");
    assert(string_equals(c.req.method, "POST"), "Method should be POST");
    assert(c.req.content_length == 13, "Content-Length should be 13, got %", c.req.content_length);
    assert(string_equals(c.req.body, "Hello, World!"), "Body should be 'Hello, World!', got '%'", c.req.body);

    print("  PASS: test_parse_body\n");
}

test_parse_body_incomplete :: () {
    c: Connection;
    // Headers say 20 bytes but only 5 present
    fill_request(*c, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 20\r\n\r\nHello");
    result := parse_request(*c);
    assert(result == .INCOMPLETE, "Should be incomplete when body not fully received");
    assert(c.parse_state == .BODY, "Should be in BODY state");

    print("  PASS: test_parse_body_incomplete\n");
}

test_parse_body_zero_length :: () {
    c: Connection;
    fill_request(*c, "POST /empty HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    result := parse_request(*c);
    assert(result == .COMPLETE, "Zero-length body should complete");
    assert(c.req.content_length == 0);
    assert(c.req.body.count == 0, "Body should be empty");

    print("  PASS: test_parse_body_zero_length\n");
}

// -- Pipelining tests --

test_reset_for_next_request :: () {
    c: Connection;
    // Simulate two pipelined requests
    raw := "GET /first HTTP/1.1\r\nHost: a\r\n\r\nGET /second HTTP/1.1\r\nHost: b\r\n\r\n";
    fill_request(*c, raw);

    // Parse first request
    result := parse_request(*c);
    assert(result == .COMPLETE);
    assert(string_equals(c.req.path, "/first"), "First path should be /first");

    // Reset and parse second request
    reset_for_next_request(*c);
    result = parse_request(*c);
    assert(result == .COMPLETE, "Second request should parse completely");
    assert(string_equals(c.req.path, "/second"), "Second path should be /second");

    print("  PASS: test_reset_for_next_request\n");
}

// -- Response helper tests --

test_response_json :: () {
    resp: Response;
    json(*resp, "{\"ok\":true}");
    assert(string_equals(resp.content_type, "application/json"), "Content-Type should be application/json");
    assert(string_equals(resp.body, "{\"ok\":true}"));
    print("  PASS: test_response_json\n");
}

test_response_text :: () {
    resp: Response;
    text(*resp, "hello");
    assert(string_equals(resp.content_type, "text/plain"));
    assert(string_equals(resp.body, "hello"));
    print("  PASS: test_response_text\n");
}

test_response_html :: () {
    resp: Response;
    html(*resp, "<h1>Hi</h1>");
    assert(string_equals(resp.content_type, "text/html"));
    assert(string_equals(resp.body, "<h1>Hi</h1>"));
    print("  PASS: test_response_html\n");
}

test_response_redirect :: () {
    resp: Response;
    redirect(*resp, "/login");
    assert(resp.status_code == 302, "Default redirect should be 302, got %", resp.status_code);
    val, found := get_header_from_response(*resp, "Location");
    assert(found, "Should have Location header");
    assert(string_equals(val, "/login"), "Location should be /login");
    assert(resp.body.count == 0, "Redirect body should be empty");
    print("  PASS: test_response_redirect\n");
}

test_response_redirect_301 :: () {
    resp: Response;
    redirect(*resp, "/new-place", 301);
    assert(resp.status_code == 301, "Should be 301");
    val, found := get_header_from_response(*resp, "Location");
    assert(found);
    assert(string_equals(val, "/new-place"));
    print("  PASS: test_response_redirect_301\n");
}

// Helper to look up response headers (analogous to get_header for requests)
get_header_from_response :: (resp: *Response, name: string) -> string, bool {
    for i: 0..cast(s64) resp.header_count - 1 {
        if string_equals_ci(resp.headers[i].name, name) {
            return resp.headers[i].value, true;
        }
    }
    result: string;
    return result, false;
}

// -- URL decode tests --

test_url_decode_no_encoding :: () {
    result := url_decode("hello");
    assert(string_equals(result, "hello"), "No encoding should return original");
    print("  PASS: test_url_decode_no_encoding\n");
}

test_url_decode_percent :: () {
    result := url_decode("hello%20world");
    assert(string_equals(result, "hello world"), "%%20 should decode to space, got '%'", result);
    print("  PASS: test_url_decode_percent\n");
}

test_url_decode_plus :: () {
    result := url_decode("hello+world");
    assert(string_equals(result, "hello world"), "+ should decode to space");
    print("  PASS: test_url_decode_plus\n");
}

test_url_decode_mixed :: () {
    result := url_decode("a%2Fb%3Dc+d");
    assert(string_equals(result, "a/b=c d"), "Mixed encoding should decode correctly, got '%'", result);
    print("  PASS: test_url_decode_mixed\n");
}

test_url_decode_uppercase_hex :: () {
    result := url_decode("%2F%2f");
    assert(string_equals(result, "//"), "Both upper and lower hex should work");
    print("  PASS: test_url_decode_uppercase_hex\n");
}

// -- Query param tests --

test_query_param_basic :: () {
    req := Request.{ query_string = "name=alice&age=30" };
    val, found := query_param(*req, "name");
    assert(found, "Should find 'name'");
    assert(string_equals(val, "alice"), "name should be alice, got '%'", val);

    val2, found2 := query_param(*req, "age");
    assert(found2, "Should find 'age'");
    assert(string_equals(val2, "30"));
    print("  PASS: test_query_param_basic\n");
}

test_query_param_missing :: () {
    req := Request.{ query_string = "name=alice" };
    _, found := query_param(*req, "missing");
    assert(!found, "Should not find 'missing'");
    print("  PASS: test_query_param_missing\n");
}

test_query_param_encoded :: () {
    req := Request.{ query_string = "q=hello+world&path=%2Fhome" };
    val, found := query_param(*req, "q");
    assert(found);
    assert(string_equals(val, "hello world"), "Should decode +, got '%'", val);

    val2, found2 := query_param(*req, "path");
    assert(found2);
    assert(string_equals(val2, "/home"), "Should decode %%2F, got '%'", val2);
    print("  PASS: test_query_param_encoded\n");
}

test_query_param_empty_value :: () {
    req := Request.{ query_string = "flag&name=bob" };
    val, found := query_param(*req, "flag");
    assert(found, "Should find 'flag' even without value");
    assert(val.count == 0, "Flag value should be empty");

    val2, found2 := query_param(*req, "name");
    assert(found2);
    assert(string_equals(val2, "bob"));
    print("  PASS: test_query_param_empty_value\n");
}

test_query_param_empty_qs :: () {
    req: Request;
    _, found := query_param(*req, "anything");
    assert(!found, "Empty query string should find nothing");
    print("  PASS: test_query_param_empty_qs\n");
}

// -- Form parsing tests --

test_parse_form_basic :: () {
    c: Connection;
    fill_request(*c, "POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Length: 23\r\n\r\nuser=alice&password=s3c");
    result := parse_request(*c);
    assert(result == .COMPLETE);

    form := parse_form(*c.req);
    assert(form.count == 2, "Should have 2 form values, got %", form.count);

    val, found := form_value(*form, "user");
    assert(found, "Should find 'user'");
    assert(string_equals(val, "alice"), "user should be alice");

    val2, found2 := form_value(*form, "password");
    assert(found2, "Should find 'password'");
    assert(string_equals(val2, "s3c"), "password should be s3c");

    print("  PASS: test_parse_form_basic\n");
}

test_parse_form_encoded :: () {
    c: Connection;
    body := "name=hello+world&path=%2Fhome%2Fuser";
    raw := tprint("POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Length: %\r\n\r\n%", body.count, body);
    fill_request(*c, raw);
    result := parse_request(*c);
    assert(result == .COMPLETE);

    form := parse_form(*c.req);
    assert(form.count == 2);

    val, found := form_value(*form, "name");
    assert(found);
    assert(string_equals(val, "hello world"), "Should decode +, got '%'", val);

    val2, found2 := form_value(*form, "path");
    assert(found2);
    assert(string_equals(val2, "/home/user"), "Should decode percent, got '%'", val2);
    print("  PASS: test_parse_form_encoded\n");
}

test_parse_form_empty_body :: () {
    req: Request;
    form := parse_form(*req);
    assert(form.count == 0, "Empty body should have 0 form values");
    print("  PASS: test_parse_form_empty_body\n");
}

test_form_value_missing :: () {
    form: Form_Data;
    _, found := form_value(*form, "anything");
    assert(!found, "Empty form should find nothing");
    print("  PASS: test_form_value_missing\n");
}

// -- Multipart parsing tests --

test_parse_multipart_basic :: () {
    boundary := "----boundary123";
    body := "------boundary123\r\nContent-Disposition: form-data; name=\"field1\"\r\n\r\nvalue1\r\n------boundary123\r\nContent-Disposition: form-data; name=\"field2\"\r\n\r\nvalue2\r\n------boundary123--";
    ct := tprint("multipart/form-data; boundary=----boundary123");
    raw := tprint("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: %\r\nContent-Length: %\r\n\r\n%", ct, body.count, body);

    c: Connection;
    fill_request(*c, raw);
    result := parse_request(*c);
    assert(result == .COMPLETE, "Should parse completely");

    data, ok := parse_multipart(*c.req);
    assert(ok, "parse_multipart should succeed");
    assert(data.count == 2, "Should have 2 parts, got %", data.count);

    p1 := multipart_value(*data, "field1");
    assert(p1 != null, "Should find field1");
    assert(string_equals(p1.body, "value1"), "field1 body should be 'value1', got '%'", p1.body);

    p2 := multipart_value(*data, "field2");
    assert(p2 != null, "Should find field2");
    assert(string_equals(p2.body, "value2"), "field2 body should be 'value2', got '%'", p2.body);

    print("  PASS: test_parse_multipart_basic\n");
}

test_parse_multipart_with_filename :: () {
    body := "------b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\nContent-Type: text/plain\r\n\r\nhello file\r\n------b--";
    ct := "multipart/form-data; boundary=----b";
    raw := tprint("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: %\r\nContent-Length: %\r\n\r\n%", ct, body.count, body);

    c: Connection;
    fill_request(*c, raw);
    result := parse_request(*c);
    assert(result == .COMPLETE);

    data, ok := parse_multipart(*c.req);
    assert(ok, "parse_multipart should succeed");
    assert(data.count == 1, "Should have 1 part, got %", data.count);

    p := multipart_value(*data, "file");
    assert(p != null, "Should find 'file' part");
    assert(string_equals(p.filename, "test.txt"), "filename should be test.txt, got '%'", p.filename);
    assert(string_equals(p.content_type, "text/plain"), "content_type should be text/plain, got '%'", p.content_type);
    assert(string_equals(p.body, "hello file"), "body should be 'hello file', got '%'", p.body);

    print("  PASS: test_parse_multipart_with_filename\n");
}

test_parse_multipart_missing_header :: () {
    req: Request;
    data, ok := parse_multipart(*req);
    assert(!ok, "Should fail without Content-Type header");
    print("  PASS: test_parse_multipart_missing_header\n");
}

test_multipart_value_missing :: () {
    data: Multipart_Data;
    p := multipart_value(*data, "nope");
    assert(p == null, "Should return null for missing part");
    print("  PASS: test_multipart_value_missing\n");
}

main :: () {
    print("Running tests...\n\n");

    print("Connection struct:\n");
    test_connection_struct();

    print("\nConnection pool:\n");
    test_pool_init();
    test_pool_get_connection();
    test_pool_exhaust();
    test_pool_free_and_reuse();
    test_pool_instance_bit();
    test_pool_connections_are_distinct();

    print("\nEvent engine:\n");
    test_encode_decode_connection_ptr();
    test_stale_event_detection();
    test_event_engine_init_destroy();

    print("\nHTTP parser:\n");
    test_parse_simple_get();
    test_parse_multiple_headers();
    test_parse_incomplete();
    test_parse_incremental();

    print("\nKeep-alive detection:\n");
    test_keepalive_http11_default();
    test_keepalive_http10_default();
    test_keepalive_http11_explicit_close();
    test_keepalive_http10_explicit_keepalive();
    test_keepalive_case_insensitive();

    print("\nHeader helpers:\n");
    test_get_header();
    test_set_header();

    print("\nQuery string:\n");
    test_parse_query_string();
    test_parse_no_query_string();

    print("\nRequest body:\n");
    test_parse_body();
    test_parse_body_incomplete();
    test_parse_body_zero_length();

    print("\nPipelining:\n");
    test_reset_for_next_request();

    print("\nResponse helpers:\n");
    test_response_json();
    test_response_text();
    test_response_html();
    test_response_redirect();
    test_response_redirect_301();

    print("\nURL decode:\n");
    test_url_decode_no_encoding();
    test_url_decode_percent();
    test_url_decode_plus();
    test_url_decode_mixed();
    test_url_decode_uppercase_hex();

    print("\nQuery params:\n");
    test_query_param_basic();
    test_query_param_missing();
    test_query_param_encoded();
    test_query_param_empty_value();
    test_query_param_empty_qs();

    print("\nForm parsing:\n");
    test_parse_form_basic();
    test_parse_form_encoded();
    test_parse_form_empty_body();
    test_form_value_missing();

    print("\nMultipart parsing:\n");
    test_parse_multipart_basic();
    test_parse_multipart_with_filename();
    test_parse_multipart_missing_header();
    test_multipart_value_missing();

    print("\nAll tests passed.\n");
}

#import "Basic";
#import "http_server";
