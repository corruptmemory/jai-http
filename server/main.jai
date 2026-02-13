#import "http_server";

hello_handler :: (request: *Request, response: *Response) {
    response.status_code = 200;
    response.body = "Hello, World!";
}

main :: () {
    router: Router;
    get(*router, "/", hello_handler);

    server: Server;
    ok := init_server(*server);
    if !ok {
        print("Failed to initialize server\n");
        return;
    }
    defer destroy_server(*server);

    serve(*server, *router);

    ok = server_listen(*server, "0.0.0.0", 9090);
    if !ok {
        print("Failed to listen\n");
        return;
    }

    server_run(*server);
}

#import "Basic";
