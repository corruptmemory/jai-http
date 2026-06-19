#import "http_server";                  // core: Request, Response, Server, init_server, ... (ambient HTTP vocabulary)
http_router :: #import "http_router";   // optional routing layer, explicitly namespaced

hello_handler :: (request: *Request, response: *Response) {
    response.status_code = 200;
    response.body = "Hello, World!";
}

main :: () {
    router: http_router.Router;
    http_router.get(*router, "/", hello_handler);

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
