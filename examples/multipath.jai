// Multi-path load/pressure example: 10 routes (static, param, wildcard) registered via the
// compile-time macros, all served by one trivial handler. Handlers are deliberately trivial —
// this measures the router (trie dispatch) + server under many distinct paths hammered
// concurrently, not handler work. Drive it with wrk + a path-rotating Lua script.
#import "http_server"()(Handler_Data = http_router.Router);
http_router :: #import "http_router";

ok_handler :: (request: *Request, response: *Response) {
    response.status_code = 200;
    response.body = "ok";
}

main :: () {
    router: http_router.Router;

    // 10 paths: static, deeper static, single param, nested param, param leaf, wildcard, versioned.
    http_router.get(*router, "/",                     ok_handler);
    http_router.get(*router, "/health",               ok_handler);
    http_router.get(*router, "/api/status",           ok_handler);
    http_router.get(*router, "/api/users",            ok_handler);
    http_router.get(*router, "/api/users/:id",        ok_handler);
    http_router.get(*router, "/api/users/:id/posts",  ok_handler);
    http_router.get(*router, "/api/posts/:id",        ok_handler);
    http_router.get(*router, "/static/*filepath",     ok_handler);
    http_router.get(*router, "/api/v1/info",          ok_handler);
    http_router.get(*router, "/api/v2/info",          ok_handler);

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
