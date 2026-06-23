// Demonstrates reclaiming the program-wide Handler_Data slot for your OWN app state, while still
// using the router — by making the app-state struct structurally IS-A Router (embed it via
// `#as using`). Then:
//   - *App implicitly converts to *Router, so http_router dispatches cast-free through it; and
//   - handlers read the full, typed app state straight off context.handler_data (also cast-free).
//
// Contrast examples/hello_world.jai, where Handler_Data is exactly http_router.Router (no app state).

#import "http_server"()(Handler_Data = App);   // main sets the program-wide handler-state type to App
http_router :: #import "http_router";

App :: struct {
    #as using router: http_router.Router;   // IS-A Router: *App converts to *Router (the #as does it)
    greeting: string;                         // your own state, carried alongside the router
}

home :: (request: *Request, response: *Response) {
    app := context.handler_data;             // already typed *App — no cast
    response.status_code = 200;
    response.body = app.greeting;            // read app state in the handler, cast-free
}

main :: () {
    app := App.{ greeting = "Hello from typed app state!" };
    http_router.get(*app, "/", home);        // *App passed where *Router is expected (implicit #as conversion)

    server: Server;
    ok := init_server(*server);
    if !ok {
        print("Failed to initialize server\n");
        return;
    }
    defer destroy_server(*server);

    http_router.serve(*server, *app);        // *App -> *Router; route_handler dispatches via the embedded router

    ok = server_listen(*server, "0.0.0.0", 9090);
    if !ok {
        print("Failed to listen\n");
        return;
    }

    server_run(*server);
}

#import "Basic";
