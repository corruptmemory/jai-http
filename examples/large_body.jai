// A 1 MB response body on every request, for exercising the pending-output path against a real
// TCP client: `curl --limit-rate 50k` makes the socket fill, so the tail queues on EPOLLOUT.
#import "http_server"()(Handler_Data = http_router.Router);
http_router :: #import "http_router";

large_body: string;

large_handler :: (request: *Request, response: *Response) {
    response.status_code  = 200;
    response.content_type = "application/octet-stream";
    response.body         = large_body;
}

main :: () {
    large_body = alloc_string(1048576);
    memset(large_body.data, #char "x", large_body.count);

    router: http_router.Router;
    http_router.get(*router, "/", large_handler);

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
