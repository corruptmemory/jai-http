#import "http_server";

// A bare handler invoked WITHOUT routing. The core server calls it directly via the generic
// Handler contract — no Router, no dispatch, no pattern matching. Bound state (if any) would
// arrive through context.handler_data; this one is stateless. Compare against examples/
// hello_world.jai (identical response, but routed) to measure the routing layer's cost.
hello_handler :: (request: *Request, response: *Response) {
    response.status_code = 200;
    response.body = "Hello, World!";
}

main :: () {
    server: Server;
    ok := init_server(*server);
    if !ok {
        print("Failed to initialize server\n");
        return;
    }
    defer destroy_server(*server);

    serve(*server, hello_handler);   // no Router — the handler is wired straight into the core

    ok = server_listen(*server, "0.0.0.0", 9090);
    if !ok {
        print("Failed to listen\n");
        return;
    }

    server_run(*server);
}

#import "Basic";
