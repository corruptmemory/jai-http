
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

// -- Socket helpers for the send-path tests --
//
// A connected AF_UNIX pair. fds[0] is the server side (non-blocking), fds[1] the peer. A small
// SO_SNDBUF on the server side makes the kernel refuse bytes early, which is how these tests
// force the pending path deterministically, without sleeping.
make_socket_pair :: (server_sndbuf: s32 = 0) -> (server: s32, peer: s32) {
    fds: [2] s32;
    r := socketpair(AF_UNIX, .SOCK_STREAM | .SOCK_NONBLOCK | .SOCK_CLOEXEC, .IP, *fds);
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

// Byte offset of the first `needle` in `haystack`, or -1. The String module's finder is not
// imported here: its contains/starts_with would collide with the helpers in this file.
index_of :: (haystack: string, needle: string) -> s64 {
    i: s64 = 0;
    while i + needle.count <= haystack.count {
        match := true;
        for j: 0..needle.count - 1  if haystack[i + j] != needle[j] { match = false; break; }
        if match  return i;
        i += 1;
    }
    return -1;
}

contains :: (haystack: string, needle: string) -> bool {
    return index_of(haystack, needle) >= 0;
}

count_occurrences :: (s: string, needle: string) -> s64 {
    n: s64 = 0;
    pos: s64 = 0;
    while pos + needle.count <= s.count {
        rest: string;
        rest.data  = s.data + pos;
        rest.count = s.count - pos;
        i := index_of(rest, needle);
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
    header_end := index_of(out, "\r\n\r\n");
    assert(header_end >= 0, "header terminator missing");
    received_body := out.count - (header_end + 4);
    assert(received_body == body.count, "peer must receive the whole body: % of %", received_body, body.count);
    received: string;
    received.data  = out.data + header_end + 4;
    received.count = received_body;
    assert(count_byte(received, #char "x") == body.count, "body bytes intact");   // body only: "text/plain" has an x
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
    assert(out.count == index_of(out, "\r\n\r\n") + 4, "HEAD must send nothing after the headers, got '%'", out);
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
    assert(out.count == index_of(out, "\r\n\r\n") + 4, "204 must send no body, got '%'", out);
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
    body_x := count_byte(out, #char "x") - count_occurrences(out, "text/plain");   // each header has one x
    assert(body_x == 2 * big_test_body.count, "both bodies intact and in full: % of %", body_x, 2 * big_test_body.count);
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
    // ~8 KB of requests behind the stalled response, in ONE write: AF_UNIX charges every write
    // its full skb truesize (~1 KB for 28 bytes), so 300 small writes overflow the peer's SO_SNDBUF.
    batch: [..] u8;
    defer array_free(batch);
    for 1..300  append_bytes(*batch, one.data, one.count);
    send_to_server(peer, as_string(batch));
    handle_client(*w, c, EPOLLIN);
    assert(c.state == .ACTIVE, "a full buffer behind pending output is not a 431");
    assert(c.read_stalled, "read must be marked stalled, not refused");
    assert(test_handler_calls == 1, "nothing dispatched while pending, got %", test_handler_calls);

    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while test_handler_calls < 301 || c.pending.count > 0 {
        got.count = 0;   // ~77 MB crosses the wire; keep only the current chunk
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

test_handle_client_half_close_serves_pipelined :: () {
    big_test_body = big_body(262144);
    defer free(big_test_body);
    w: Worker;
    make_test_worker(*w, big_handler);
    defer destroy_test_worker(*w);
    server, peer := make_socket_pair(server_sndbuf = 4096);
    defer close(peer);
    c := attach(*w, server);

    // Two pipelined keep-alive requests, then the peer's FIN, all before the server looks.
    send_to_server(peer, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    shutdown(peer, .WR);
    handle_client(*w, c, EPOLLIN | EPOLLRDHUP);
    assert(c.state == .ACTIVE && c.pending.count > 0, "the first response stalls; the connection must wait for it");
    assert(c.peer_closed && !c.close_after_send, "a FIN is not a Connection: close; the second request is still owed");

    got: [..] u8;
    defer array_free(got);
    rounds := 0;
    while c.state == .ACTIVE {
        drain_peer(peer, *got);
        handle_client(*w, c, EPOLLOUT);
        rounds += 1;
        assert(rounds < 100000, "never drained");
    }
    drain_peer(peer, *got);
    out := as_string(got);
    assert(test_handler_calls == 2, "both pipelined requests answered before the close, got %", test_handler_calls);
    assert(count_occurrences(out, "HTTP/1.1 200 OK\r\n") == 2, "two responses on the wire");
    print("  PASS: test_handle_client_half_close_serves_pipelined\n");
}

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

    print("\nSend-path state:\n");
    test_pending_defaults_and_release();

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

    print("\nEvent handling:\n");
    test_parse_error_classification();
    test_handle_client_out_with_nothing_queued_is_ignored();
    test_handle_client_answers_before_honoring_rdhup();
    test_handle_client_pending_blocks_dispatch();
    test_handle_client_full_buffer_while_pending_stalls_read();
    test_handle_client_oversized_header_gets_431();
    test_handle_client_oversized_body_gets_413();
    test_handle_client_malformed_gets_400();
    test_handle_client_half_close_serves_pipelined();

    print("\nTimeouts:\n");
    test_timeout_state_classification();
    test_is_timed_out_uses_the_right_clock();
    test_is_timed_out_write_then_idle();
    test_check_timeouts_closes_idle_silently();
    test_check_timeouts_sends_408_for_a_slow_header();
    test_check_timeouts_skips_free_slots_and_listener();

    print("\nDate header and buffer shift:\n");
    test_format_http_date();
    test_refresh_date_caches_per_second();
    test_reset_shift_overlapping_and_disjoint();

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
#import "Socket";
#import "POSIX";
#import "Pool";
#import "Linux";
