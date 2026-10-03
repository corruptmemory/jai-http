// A large response body on every request, for exercising the pending-output path against a real
// TCP client. Loopback socket buffers absorb a megabyte or more without queueing anything, so the
// body is 8 MB, and the per-connection tail cap is raised to 16 MB. MAX_PENDING_BYTES is a
// program-wide (group 2) parameter, so the main program sets it here and http_router's import of
// http_server sees the same value. With a slow reader,
//     curl --limit-rate 1M -o /dev/null http://localhost:9090/
// the socket fills, the unsent tail queues on the connection and drains on EPOLLOUT.
#import "http_server"()(Handler_Data = http_router.Router, MAX_PENDING_BYTES = 16777216);
http_router :: #import "http_router";

large_body: string;

large_handler :: (request: *Request, response: *Response) {
    response.status_code  = 200;
    response.content_type = "application/octet-stream";
    response.body         = large_body;
}

main :: () {
    large_body = alloc_string(8 * 1048576);
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
