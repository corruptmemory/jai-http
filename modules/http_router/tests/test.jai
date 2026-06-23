
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

    print("\nAll http_router tests passed.\n");
}

#import "Basic";
// Main program sets the program-wide Handler_Data = Router so the dispatch adapter is cast-free.
// `Router` resolves via the anonymous http_router import below (order-independent). Both modules
// imported anonymously so routing symbols stay unqualified; the two `serve`s form an overload set
// but are never called here (tests drive dispatch() directly), so no collision.
#import "http_server"()(Handler_Data = Router);   // Request, Response, string_equals
#import "http_router";                            // Router, get/post, dispatch, param, proceed, use, mount, HTTP_Context, Middleware
