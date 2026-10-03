
// http_router test suite — pattern matching, dispatch, middleware, mounting, context.
//
// Imports the core anonymously (Request/Response/string_equals) and the routing layer it tests.
// Both resolve to the same default-parameterized http_server instance (dedup), so Request/Response
// are identical types across the boundary. These tests call dispatch() directly, never serve(),
// so the core's serve and http_router's serve never need disambiguation here.

// -- Router: wildcard dispatch tests --

wildcard_captured_path: string;

wildcard_handler :: (req: *Request, resp: *Response) {
    fp, found := param("filepath");
    assert(found, "Should find wildcard param 'filepath'");
    wildcard_captured_path = fp;
    resp.status_code = 200;
}

test_dispatch_wildcard :: () {
    router: Router;
    get(*router, "/static/*filepath", wildcard_handler);

    req := Request.{ method = "GET", path = "/static/js/app.min.js" };
    resp: Response;

    wildcard_captured_path = "";
    dispatch(*router, *req, *resp);
    assert(resp.status_code == 200, "Should match wildcard route");
    assert(string_equals(wildcard_captured_path, "js/app.min.js"), "Should capture 'js/app.min.js', got '%'", wildcard_captured_path);

    print("  PASS: test_dispatch_wildcard\n");
}

// -- Router: dispatch tests --

test_handler_called: bool;
test_handler_path:   string;

simple_test_handler :: (req: *Request, resp: *Response) {
    test_handler_called = true;
    test_handler_path = req.path;
    resp.status_code = 200;
    resp.body = "OK";
}

test_dispatch_basic :: () {
    router: Router;
    get(*router, "/hello", simple_test_handler);

    req := Request.{ method = "GET", path = "/hello" };
    resp: Response;

    test_handler_called = false;
    dispatch(*router, *req, *resp);
    assert(test_handler_called, "Handler should have been called");
    assert(resp.status_code == 200, "Status should be 200");

    print("  PASS: test_dispatch_basic\n");
}

test_dispatch_404 :: () {
    router: Router;
    get(*router, "/hello", simple_test_handler);

    req := Request.{ method = "GET", path = "/missing" };
    resp: Response;

    test_handler_called = false;
    dispatch(*router, *req, *resp);
    assert(!test_handler_called, "Handler should not have been called");
    assert(resp.status_code == 404, "Status should be 404, got %", resp.status_code);

    print("  PASS: test_dispatch_404\n");
}

test_dispatch_405 :: () {
    router: Router;
    get(*router, "/hello", simple_test_handler);

    req := Request.{ method = "POST", path = "/hello" };
    resp: Response;

    test_handler_called = false;
    dispatch(*router, *req, *resp);
    assert(!test_handler_called, "Handler should not have been called for wrong method");
    assert(resp.status_code == 405, "Status should be 405, got %", resp.status_code);

    print("  PASS: test_dispatch_405\n");
}

test_dispatch_method_filtering :: () {
    router: Router;
    post(*router, "/submit", simple_test_handler);

    req := Request.{ method = "GET", path = "/submit" };
    resp: Response;

    test_handler_called = false;
    dispatch(*router, *req, *resp);
    assert(!test_handler_called, "GET should not match POST route");
    assert(resp.status_code == 405, "Should be 405 for wrong method");

    // Now test with correct method
    req.method = "POST";
    resp = .{};
    test_handler_called = false;
    dispatch(*router, *req, *resp);
    assert(test_handler_called, "POST should match POST route");
    assert(resp.status_code == 200);

    print("  PASS: test_dispatch_method_filtering\n");
}

// -- Router: param access via context --

param_test_captured_id: string;

param_capture_handler :: (req: *Request, resp: *Response) {
    id, found := param("id");
    assert(found, "Should find param 'id'");
    param_test_captured_id = id;
    resp.status_code = 200;
}

test_dispatch_param_access :: () {
    router: Router;
    get(*router, "/users/:id", param_capture_handler);

    req := Request.{ method = "GET", path = "/users/42" };
    resp: Response;

    param_test_captured_id = "";
    dispatch(*router, *req, *resp);
    assert(string_equals(param_test_captured_id, "42"), "Should capture id=42, got '%'", param_test_captured_id);
    assert(resp.status_code == 200);

    print("  PASS: test_dispatch_param_access\n");
}

// -- Router: middleware tests --

mw_test_order: [8] s32;
mw_test_count: s32;

record_order :: (val: s32) {
    if mw_test_count < 8 {
        mw_test_order[mw_test_count] = val;
        mw_test_count += 1;
    }
}

middleware_a :: (ctx: *HTTP_Context) {
    record_order(1);
    proceed(ctx);
    record_order(4);
}

middleware_b :: (ctx: *HTTP_Context) {
    record_order(2);
    proceed(ctx);
    record_order(3);
}

mw_test_handler :: (req: *Request, resp: *Response) {
    record_order(10);
    resp.status_code = 200;
}

test_middleware_chain :: () {
    router: Router;
    use(*router, middleware_a);
    use(*router, middleware_b);
    get(*router, "/test", mw_test_handler);

    req := Request.{ method = "GET", path = "/test" };
    resp: Response;

    mw_test_count = 0;
    dispatch(*router, *req, *resp);

    assert(resp.status_code == 200, "Handler should have run");
    assert(mw_test_count == 5, "Should have 5 order records, got %", mw_test_count);
    assert(mw_test_order[0] == 1,  "First should be middleware_a enter (1)");
    assert(mw_test_order[1] == 2,  "Second should be middleware_b enter (2)");
    assert(mw_test_order[2] == 10, "Third should be handler (10)");
    assert(mw_test_order[3] == 3,  "Fourth should be middleware_b exit (3)");
    assert(mw_test_order[4] == 4,  "Fifth should be middleware_a exit (4)");

    print("  PASS: test_middleware_chain\n");
}

// -- Router: middleware short-circuit --

blocking_middleware :: (ctx: *HTTP_Context) {
    // Short-circuit: set 403 and don't call proceed
    ctx.resp.status_code = 403;
    ctx.resp.body = "Forbidden";
}

test_middleware_short_circuit :: () {
    router: Router;
    use(*router, blocking_middleware);
    get(*router, "/secret", simple_test_handler);

    req := Request.{ method = "GET", path = "/secret" };
    resp: Response;

    test_handler_called = false;
    dispatch(*router, *req, *resp);
    assert(!test_handler_called, "Handler should NOT have been called when middleware short-circuits");
    assert(resp.status_code == 403, "Should get 403 from blocking middleware");

    print("  PASS: test_middleware_short_circuit\n");
}

// -- Router: sub-router mounting --

sub_handler_called: bool;
sub_handler_path:   string;

sub_test_handler :: (req: *Request, resp: *Response) {
    sub_handler_called = true;
    sub_handler_path = req.path;
    resp.status_code = 200;
    resp.body = "sub OK";
}

test_mount_basic :: () {
    api_router: Router;
    get(*api_router, "/users", sub_test_handler);

    root: Router;
    mount(*root, "/api", *api_router);

    req := Request.{ method = "GET", path = "/api/users" };
    resp: Response;

    sub_handler_called = false;
    dispatch(*root, *req, *resp);
    assert(sub_handler_called, "Sub-router handler should have been called");
    assert(resp.status_code == 200);

    print("  PASS: test_mount_basic\n");
}

test_mount_404 :: () {
    api_router: Router;
    get(*api_router, "/users", sub_test_handler);

    root: Router;
    mount(*root, "/api", *api_router);

    req := Request.{ method = "GET", path = "/api/missing" };
    resp: Response;

    sub_handler_called = false;
    dispatch(*root, *req, *resp);
    assert(!sub_handler_called, "Sub-router handler should not be called for missing route");
    assert(resp.status_code == 404, "Should be 404 for missing sub-route");

    print("  PASS: test_mount_404\n");
}

// -- Router: mounted sub-router with parent middleware --

mount_mw_order: [8] s32;
mount_mw_count: s32;

mount_record_order :: (val: s32) {
    if mount_mw_count < 8 {
        mount_mw_order[mount_mw_count] = val;
        mount_mw_count += 1;
    }
}

parent_mw :: (ctx: *HTTP_Context) {
    mount_record_order(1);
    proceed(ctx);
}

sub_mw :: (ctx: *HTTP_Context) {
    mount_record_order(2);
    proceed(ctx);
}

mount_handler :: (req: *Request, resp: *Response) {
    mount_record_order(3);
    resp.status_code = 200;
}

test_mount_middleware_order :: () {
    sub_router: Router;
    use(*sub_router, sub_mw);
    get(*sub_router, "/items", mount_handler);

    root: Router;
    use(*root, parent_mw);
    mount(*root, "/api", *sub_router);

    req := Request.{ method = "GET", path = "/api/items" };
    resp: Response;

    mount_mw_count = 0;
    dispatch(*root, *req, *resp);

    assert(resp.status_code == 200);
    assert(mount_mw_count == 3, "Should have 3 order records, got %", mount_mw_count);
    assert(mount_mw_order[0] == 1, "Parent middleware should run first");
    assert(mount_mw_order[1] == 2, "Sub middleware should run second");
    assert(mount_mw_order[2] == 3, "Handler should run third");

    print("  PASS: test_mount_middleware_order\n");
}

// -- Router: context.http is set during handler --

context_http_was_set: bool;

context_check_handler :: (req: *Request, resp: *Response) {
    context_http_was_set = context.http != null;
    resp.status_code = 200;
}

test_context_http_set :: () {
    router: Router;
    get(*router, "/check", context_check_handler);

    req := Request.{ method = "GET", path = "/check" };
    resp: Response;

    context_http_was_set = false;
    dispatch(*router, *req, *resp);
    assert(context_http_was_set, "context.http should be set during handler execution");

    print("  PASS: test_context_http_set\n");
}

// -- Trie: parse_pattern --

test_parse_simple :: () {
    segs, ok, err := parse_pattern("/users/:id");
    assert(ok, "should parse, err='%'", err);
    assert(segs.count == 2, "expected 2 segments, got %", segs.count);
    assert(segs[0].kind == .STATIC && string_equals(segs[0].name, "users"), "seg0 STATIC users");
    assert(segs[1].kind == .PARAM  && string_equals(segs[1].name, "id"),    "seg1 PARAM id");
    print("  PASS: test_parse_simple\n");
}

test_parse_root :: () {
    segs, ok, _ := parse_pattern("/");
    assert(ok, "root parses");
    assert(segs.count == 0, "root has zero segments, got %", segs.count);
    print("  PASS: test_parse_root\n");
}

test_parse_wildcard :: () {
    segs, ok, _ := parse_pattern("/static/*filepath");
    assert(ok);
    assert(segs.count == 2);
    assert(segs[0].kind == .STATIC   && string_equals(segs[0].name, "static"));
    assert(segs[1].kind == .WILDCARD && string_equals(segs[1].name, "filepath"), "seg1 WILDCARD filepath");
    print("  PASS: test_parse_wildcard\n");
}

test_parse_malformed :: () {
    _, ok, err := parse_pattern("/a/*rest/b");
    assert(!ok, "non-terminal wildcard must fail");
    assert(err.count > 0, "should carry an error message");
    print("  PASS: test_parse_malformed\n");
}

// -- Trie: build_partial_tree --

test_build_simple_param :: () {
    t, ok := build_partial_tree("GET", "/users/:id", simple_test_handler);
    assert(ok, "build should succeed");
    assert(t.nodes.count == 3, "expected 3 nodes, got %", t.nodes.count);
    assert(t.nodes[0].kind == .STATIC && t.nodes[0].segment.count == 0, "node0 = root STATIC \"\"");
    assert(t.nodes[1].kind == .STATIC && string_equals(t.nodes[1].segment, "users"), "node1 = STATIC users");
    assert(t.nodes[2].kind == .PARAM  && string_equals(t.nodes[2].segment, "id"),    "node2 = PARAM id");
    assert(t.nodes[0].static_children.count == 1 && t.nodes[0].static_children[0] == 1, "root -> node1");
    assert(t.nodes[1].param_child == 2, "node1 param_child -> node2");
    assert(t.nodes[2].endpoints.count == 1, "leaf has 1 endpoint");
    assert(string_equals(t.nodes[2].endpoints[0].method, "GET"), "endpoint method GET");
    assert(t.nodes[2].endpoints[0].param_keys.count == 1, "1 param key");
    assert(string_equals(t.nodes[2].endpoints[0].param_keys[0], "id"), "param key = id");
    print("  PASS: test_build_simple_param\n");
}

test_build_root :: () {
    t, ok := build_partial_tree("GET", "/", simple_test_handler);
    assert(ok, "build / should succeed");
    assert(t.nodes.count == 1, "root-only tree, got % nodes", t.nodes.count);
    assert(t.nodes[0].endpoints.count == 1, "root is the leaf for /");
    print("  PASS: test_build_root\n");
}

test_build_wildcard :: () {
    t, ok := build_partial_tree("GET", "/static/*filepath", simple_test_handler);
    assert(ok, "build wildcard should succeed");
    assert(t.nodes.count == 3, "root, static, wildcard");
    assert(t.nodes[2].kind == .WILDCARD && string_equals(t.nodes[2].segment, "filepath"), "node2 wildcard filepath");
    assert(t.nodes[1].wildcard_child == 2, "static -> wildcard");
    assert(string_equals(t.nodes[2].endpoints[0].param_keys[0], "filepath"), "key filepath");
    print("  PASS: test_build_wildcard\n");
}

test_build_wildcard_not_last :: () {
    _, ok := build_partial_tree("GET", "/a/*rest/b", simple_test_handler);
    assert(!ok, "wildcard not last must fail");
    print("  PASS: test_build_wildcard_not_last\n");
}

// -- Trie: tree_to_string --

test_tree_dump :: () {
    t, ok := build_partial_tree("GET", "/users/:id", simple_test_handler);
    assert(ok);
    s := tree_to_string(t);
    expected := "STATIC \"\"\n  STATIC \"users\"\n    :id GET\n";
    assert(string_equals(s, expected), "dump mismatch:\n%", s);
    print("  PASS: test_tree_dump\n");
}

// -- Trie: merge --

test_merge_disjoint :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET", "/users", simple_test_handler);
    p2, _ := build_partial_tree("GET", "/posts", simple_test_handler);
    assert(merge(*acc, p1), "merge p1");
    assert(merge(*acc, p2), "merge p2");
    s := tree_to_string(acc);
    expected := "STATIC \"\"\n  STATIC \"users\" GET\n  STATIC \"posts\" GET\n";
    assert(string_equals(s, expected), "disjoint merge:\n%", s);
    print("  PASS: test_merge_disjoint\n");
}

test_merge_shared_prefix :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET", "/users/:id",          simple_test_handler);
    p2, _ := build_partial_tree("GET", "/users/:userId/posts", simple_test_handler);
    assert(merge(*acc, p1));
    assert(merge(*acc, p2));
    // Shared "users" + shared single param edge; p2 continues to "posts".
    s := tree_to_string(acc);
    expected := "STATIC \"\"\n  STATIC \"users\"\n    :id GET\n      STATIC \"posts\" GET\n";
    assert(string_equals(s, expected), "shared-prefix merge:\n%", s);
    print("  PASS: test_merge_shared_prefix\n");
}

test_merge_method_union :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET",  "/x", simple_test_handler);
    p2, _ := build_partial_tree("POST", "/x", simple_test_handler);
    assert(merge(*acc, p1));
    assert(merge(*acc, p2));
    s := tree_to_string(acc);
    expected := "STATIC \"\"\n  STATIC \"x\" GET POST\n";
    assert(string_equals(s, expected), "method-union merge:\n%", s);
    print("  PASS: test_merge_method_union\n");
}

test_merge_conflict :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET", "/dup", simple_test_handler);
    p2, _ := build_partial_tree("GET", "/dup", simple_test_handler);
    assert(merge(*acc, p1), "first registration ok");
    assert(!merge(*acc, p2), "duplicate GET /dup must conflict");
    print("  PASS: test_merge_conflict\n");
}

// -- Trie: tree_match --

build_acc :: (patterns: [] string) -> Trie {
    acc: Trie;
    for patterns {
        p, ok := build_partial_tree("GET", it, simple_test_handler);
        assert(ok, "build % ok", it);
        assert(merge(*acc, p), "merge % ok", it);
    }
    return acc;
}

test_tm_static_vs_param_backtrack :: () {
    acc := build_acc(.["/users/new", "/users/:id"]);
    params: type_of(HTTP_Context.params);
    pc: s32;

    // Static wins for the literal.
    h, st := tree_match(*acc, "GET", "/users/new", *params, *pc);
    assert(st == .MATCHED, "static /users/new matched");
    assert(pc == 0, "static path captures nothing");

    // Param matches a different value.
    h, st = tree_match(*acc, "GET", "/users/42", *params, *pc);
    assert(st == .MATCHED, "param /users/42 matched");
    assert(pc == 1 && string_equals(params[0].name, "id") && string_equals(params[0].value, "42"), "id=42");

    print("  PASS: test_tm_static_vs_param_backtrack\n");
}

test_tm_deeper_backtrack :: () {
    // /users/new is a leaf; /users/:id/edit needs the param branch even though "new" is static.
    acc := build_acc(.["/users/new", "/users/:id/edit"]);
    params: type_of(HTTP_Context.params);
    pc: s32;
    h, st := tree_match(*acc, "GET", "/users/new/edit", *params, *pc);
    assert(st == .MATCHED, "must backtrack from static 'new' to param branch");
    assert(pc == 1 && string_equals(params[0].value, "new"), "captured id=new, got '%'", params[0].value);
    print("  PASS: test_tm_deeper_backtrack\n");
}

test_tm_wildcard :: () {
    acc := build_acc(.["/static/*filepath"]);
    params: type_of(HTTP_Context.params);
    pc: s32;
    h, st := tree_match(*acc, "GET", "/static/css/app.css", *params, *pc);
    assert(st == .MATCHED, "wildcard matched");
    assert(pc == 1 && string_equals(params[0].name, "filepath"), "key filepath");
    assert(string_equals(params[0].value, "css/app.css"), "rest captured, got '%'", params[0].value);

    h, st = tree_match(*acc, "GET", "/static/", *params, *pc);
    assert(st == .NOT_FOUND, "empty wildcard remainder must not match");
    print("  PASS: test_tm_wildcard\n");
}

test_tm_404_405 :: () {
    acc: Trie;
    p, _ := build_partial_tree("GET", "/only", simple_test_handler);
    merge(*acc, p);
    params: type_of(HTTP_Context.params);
    pc: s32;

    h, st := tree_match(*acc, "GET", "/missing", *params, *pc);
    assert(st == .NOT_FOUND, "missing path -> NOT_FOUND");

    h, st = tree_match(*acc, "POST", "/only", *params, *pc);
    assert(st == .METHOD_NOT_ALLOWED, "wrong method on existing path -> METHOD_NOT_ALLOWED");

    print("  PASS: test_tm_404_405\n");
}

// -- Route macros (compile-time pattern parse) --

macro_head_called: bool;
macro_head_handler :: (req: *Request, resp: *Response) {
    macro_head_called = true;
    resp.status_code = 200;
}

test_macro_head :: () {
    router: Router;
    head(*router, "/ping", macro_head_handler);

    req := Request.{ method = "HEAD", path = "/ping" };
    resp: Response;
    macro_head_called = false;
    dispatch(*router, *req, *resp);
    assert(macro_head_called, "HEAD handler should run");
    assert(resp.status_code == 200, "HEAD /ping -> 200, got %", resp.status_code);
    print("  PASS: test_macro_head\n");
}

macro_eq_id: string;
macro_eq_handler :: (req: *Request, resp: *Response) {
    id, _ := param("id");
    macro_eq_id = id;
    resp.status_code = 200;
}

test_macro_route_equivalence :: () {
    // Same route via the get MACRO and via runtime route() must dispatch identically.
    r_macro: Router;
    get(*r_macro, "/users/:id", macro_eq_handler);

    r_runtime: Router;
    route(*r_runtime, "GET", "/users/:id", macro_eq_handler);

    req := Request.{ method = "GET", path = "/users/42" };

    resp1: Response; macro_eq_id = "";
    dispatch(*r_macro, *req, *resp1);
    assert(resp1.status_code == 200 && string_equals(macro_eq_id, "42"), "macro path: 200 + id=42, got % '%'", resp1.status_code, macro_eq_id);

    resp2: Response; macro_eq_id = "";
    dispatch(*r_runtime, *req, *resp2);
    assert(resp2.status_code == 200 && string_equals(macro_eq_id, "42"), "route() path: 200 + id=42, got % '%'", resp2.status_code, macro_eq_id);

    print("  PASS: test_macro_route_equivalence\n");
}

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

// -- Hardening from the PR #5 review (2026-10-03); R-numbers match the review report --

review_contains :: (haystack: string, needle: string) -> bool {
    i := 0;
    while i + needle.count <= haystack.count {
        match := true;
        for j: 0..needle.count - 1  if haystack[i + j] != needle[j] { match = false; break; }
        if match  return true;
        i += 1;
    }
    return false;
}

// R17. Allow is built from the FIRST leaf that matched the path but not the method. With
// overlapping routes, backtracking reaches other leaves whose methods would succeed, and they are
// left out: here POST /users/new is served by the :id route, yet Allow says only GET.
// RFC 9110 §10.2.1: Allow lists the methods the target resource supports.
test_allow_unions_overlapping_routes :: () {
    router: Router;
    get(*router, "/users/new", get_probe_handler);
    post(*router, "/users/:id", get_probe_handler);
    req := Request.{ method = "DELETE", path = "/users/new" };
    resp: Response;
    dispatch(*router, *req, *resp);
    allow, found := response_header(*resp, "Allow");
    assert(resp.status_code == 405 && found && review_contains(allow, "GET") && review_contains(allow, "POST"), "Allow must include POST (served via /users/:id) as well as GET; status %, Allow '%'", resp.status_code, allow);
    print("  PASS: test_allow_unions_overlapping_routes\n");
}

// R18. Mount prefixes are matched as raw string prefixes, not path segments: /apiary reaches the
// sub-router mounted at /api as its route /ary.
test_mount_prefix_is_segment_aligned :: () {
    api: Router;
    get(*api, "/ary", get_probe_handler);
    root: Router;
    mount(*root, "/api", *api);
    req := Request.{ method = "GET", path = "/apiary" };
    resp: Response;
    get_probe_calls = 0;
    dispatch(*root, *req, *resp);
    assert(resp.status_code == 404 && get_probe_calls == 0, "/apiary is not under the /api mount; status %, mounted handler ran %", resp.status_code, get_probe_calls);
    print("  PASS: test_mount_prefix_is_segment_aligned\n");
}

// R19. A sub-router's own mounts are never consulted: dispatch_with_middleware matches only the
// sub-router's trie, so /api/v1/users is a 404.
test_nested_mounts_dispatch :: () {
    v1: Router;
    get(*v1, "/users", get_probe_handler);
    api: Router;
    mount(*api, "/v1", *v1);
    root: Router;
    mount(*root, "/api", *api);
    req := Request.{ method = "GET", path = "/api/v1/users" };
    resp: Response;
    get_probe_calls = 0;
    dispatch(*root, *req, *resp);
    assert(resp.status_code == 200 && get_probe_calls == 1, "a route in a mount inside a mount must be reachable; status %, handler ran %", resp.status_code, get_probe_calls);
    print("  PASS: test_nested_mounts_dispatch\n");
}

// -- Hardening from the second review (Codex with the Jai reference) of the fix round: R25, R26 --

// R25 (R19 incomplete). Stripping a mount prefix that ends in '/' (or is "/") drops the leading
// slash, so the delegated path is `v1/users` and a nested `/v1` mount never matches.
test_nested_mount_under_slash_prefix :: () {
    v1: Router;
    get(*v1, "/users", get_probe_handler);
    api: Router;
    mount(*api, "/v1", *v1);
    root: Router;
    mount(*root, "/api/", *api);
    req := Request.{ method = "GET", path = "/api/v1/users" };
    resp: Response;
    get_probe_calls = 0;
    dispatch(*root, *req, *resp);

    top: Router;
    mount(*top, "/", *api);
    req2 := Request.{ method = "GET", path = "/v1/users" };
    resp2: Response;
    dispatch(*top, *req2, *resp2);
    assert(resp.status_code == 200 && resp2.status_code == 200 && get_probe_calls == 2, "nested mounts below '/api/' and '/' must resolve; statuses % and %, handler ran %", resp.status_code, resp2.status_code, get_probe_calls);
    print("  PASS: test_nested_mount_under_slash_prefix\n");
}

// R26 (partly a regression from the R17 fix). allow_header_for kept at most 32 methods, so a
// path with more registered methods silently lost GET (and its implied HEAD) from Allow.
test_allow_has_no_silent_caps :: () {
    methods :: string.["M01","M02","M03","M04","M05","M06","M07","M08","M09","M10","M11",
                       "M12","M13","M14","M15","M16","M17","M18","M19","M20","M21","M22",
                       "M23","M24","M25","M26","M27","M28","M29","M30","M31","M32","M33"];
    router: Router;
    for methods  route(*router, it, "/x", get_probe_handler);
    get(*router, "/x", get_probe_handler);
    req := Request.{ method = "DELETE", path = "/x" };
    resp: Response;
    dispatch(*router, *req, *resp);
    allow, found := response_header(*resp, "Allow");
    assert(resp.status_code == 405 && found && review_contains(allow, "M33") && review_contains(allow, "GET") && review_contains(allow, "HEAD"), "Allow must list all 34 methods plus HEAD; status %, Allow ends '...%'",
        resp.status_code, ifx allow.count > 30 then string.{30, allow.data + allow.count - 30} else allow);
    print("  PASS: test_allow_has_no_silent_caps\n");
}

main :: () {
    print("Running http_router tests...\n\n");

    print("Router - dispatch:\n");
    test_dispatch_wildcard();
    test_dispatch_basic();
    test_dispatch_404();
    test_dispatch_405();
    test_dispatch_method_filtering();
    test_dispatch_param_access();

    print("\nRouter - middleware:\n");
    test_middleware_chain();
    test_middleware_short_circuit();

    print("\nRouter - mounting:\n");
    test_mount_basic();
    test_mount_404();
    test_mount_middleware_order();

    print("\nRouter - context:\n");
    test_context_http_set();

    print("\nTrie - parse_pattern:\n");
    test_parse_simple();
    test_parse_root();
    test_parse_wildcard();
    test_parse_malformed();

    print("\nTrie - build_partial_tree:\n");
    test_build_simple_param();
    test_build_root();
    test_build_wildcard();
    test_build_wildcard_not_last();

    print("\nTrie - tree_to_string:\n");
    test_tree_dump();

    print("\nTrie - merge:\n");
    test_merge_disjoint();
    test_merge_shared_prefix();
    test_merge_method_union();
    test_merge_conflict();

    print("\nTrie - tree_match:\n");
    test_tm_static_vs_param_backtrack();
    test_tm_deeper_backtrack();
    test_tm_wildcard();
    test_tm_404_405();

    print("\nRoute macros:\n");
    test_macro_head();
    test_macro_route_equivalence();

    print("\nHEAD and Allow:\n");
    test_head_falls_back_to_get();
    test_explicit_head_route_wins();
    test_405_carries_allow();
    test_405_allow_without_get_has_no_head();
    test_mount_405_carries_allow();
    test_allow_unions_overlapping_routes();
    test_allow_has_no_silent_caps();
    test_mount_prefix_is_segment_aligned();
    test_nested_mounts_dispatch();
    test_nested_mount_under_slash_prefix();

    print("\nAll http_router tests passed.\n");
}

#import "Basic";
// Main program sets the program-wide Handler_Data = Router so the dispatch adapter is cast-free.
// `Router` resolves via the anonymous http_router import below (order-independent). Both modules
// imported anonymously so routing symbols stay unqualified; the two `serve`s form an overload set
// but are never called here (tests drive dispatch() directly), so no collision.
#import "http_server"()(Handler_Data = Router);   // Request, Response, string_equals
#import "http_router";                            // Router, get/post, dispatch, param, proceed, use, mount, HTTP_Context, Middleware
