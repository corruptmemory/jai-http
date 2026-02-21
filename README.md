# jai-http

A high-performance HTTP/1.1 server library for [Jai](https://jai.community/), built on Linux epoll with a shared-nothing worker thread pool.

## Features

- **SO_REUSEPORT workers** -- Each worker thread owns its own listen socket and epoll instance. No inter-worker locking or communication. The kernel distributes incoming connections across workers.
- **Chi-style router** -- Path params (`:name`), wildcard segments (`*name`), middleware chains, sub-router mounting.
- **`#add_context` integration** -- Per-request `HTTP_Context` is injected into Jai's implicit context. Handlers access path params via `param("id")` with no explicit context argument.
- **Per-request pool allocator** -- Each worker owns a `Pool` that resets after every request. Handler code uses `alloc()`, `New()`, dynamic arrays, etc. with automatic cleanup.
- **Zero-copy parsing** -- HTTP request parser, URL decoder, form parser, and multipart parser all produce string views into the connection read buffer where possible.
- **No external dependencies** -- Uses only Jai standard library modules.

## Performance

Benchmarked on AMD Threadripper (32-core / 64-thread) with `wrk`:

| wrk Threads | Connections | Req/sec | Avg Latency |
|-------------|-------------|---------|-------------|
| 1 | 10 | 143,808 | 4.8ms |
| 8 | 500 | 689,251 | 4.4ms |
| 16 | 1000 | 1,360,520 | 4.4ms |
| 32 | 2000 | ~1,600,000 | ~4ms |

## Quick Start

```jai
#import "http_server";

hello_handler :: (request: *Request, response: *Response) {
    text(response, "Hello, World!");
}

main :: () {
    router: Router;
    get(*router, "/", hello_handler);

    server: Server;
    ok := init_server(*server);
    if !ok return;
    defer destroy_server(*server);

    serve(*server, *router);
    server_listen(*server, "0.0.0.0", 9090);
    server_run(*server);
}
```

## Routing

Register routes with `get`, `post`, `put`, `http_delete`, or the generic `route`:

```jai
router: Router;

get(*router, "/users",     list_users);
get(*router, "/users/:id", get_user);
post(*router, "/users",    create_user);

// Wildcard -- matches rest of path
get(*router, "/static/*filepath", serve_static);
```

Access path params from any handler:

```jai
get_user :: (req: *Request, resp: *Response) {
    id, found := param("id");
    if !found { resp.status_code = 400; return; }
    json(resp, tprint("{\"id\": \"%\"}", id));
}
```

### Middleware

```jai
logger :: (ctx: *HTTP_Context) {
    // before
    proceed(ctx);
    // after
}

use(*router, logger);
```

### Sub-router Mounting

```jai
api: Router;
get(*api, "/health", health_check);
use(*api, auth_middleware);

root: Router;
mount(*root, "/api", *api);
// /api/health -> health_check (with auth_middleware)
```

## Response Helpers

```jai
json(resp, "{\"ok\": true}");
text(resp, "plain text");
html(resp, "<h1>Hello</h1>");
redirect(resp, "/login");         // 302
redirect(resp, "/new-url", 301);  // 301
```

## Form and Query Parsing

```jai
// Query params: /search?q=hello&page=2
q, _ := query_param(req, "q");

// URL-encoded form body
form := parse_form(req);
name, _ := form_value(*form, "username");

// Multipart form data
data, ok := parse_multipart(req);
file := multipart_value(*data, "avatar");
if file  print("filename: %\n", file.filename);
```

## Building

Requires the Jai compiler (`~/jai/jai/bin/jai-linux`). Tested with beta 0.2.026.

```bash
# Debug build
~/jai/jai/bin/jai-linux first.jai - debug

# Release build
~/jai/jai/bin/jai-linux first.jai - release

# Build and run tests
~/jai/jai/bin/jai-linux first.jai - test
```

Run the server:

```bash
./build_debug/server    # listens on 0.0.0.0:9090
```

## Module Parameters

All tunables are compile-time module parameters with sensible defaults:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CACHE_LINE_SIZE` | 64 | Cache line size for alignment |
| `READ_BUFFER_SIZE` | 4096 | Per-connection read buffer |
| `MAX_HEADERS` | 64 | Max headers per request/response |
| `MAX_ROUTES` | 128 | Max routes per router |
| `MAX_PARAMS` | 8 | Max path params per route |
| `MAX_MIDDLEWARE` | 16 | Max middleware per router |
| `MAX_MOUNTS` | 16 | Max sub-router mounts |
| `MAX_FORM_VALUES` | 64 | Max form fields |
| `MAX_MULTIPART_PARTS` | 16 | Max multipart parts |
| `LISTEN_BACKLOG` | 1024 | TCP listen backlog |

Override at import time:

```jai
#import "http_server"(MAX_ROUTES = 256, READ_BUFFER_SIZE = 8192);
```

## Architecture

```
server/main.jai          -- Example server entry point
modules/http_server/
  module.jai             -- Module definition, parameters, imports
  http.jai               -- Request/Response types, zero-copy parser, serializer
  connection.jai         -- Connection pool with free list, instance-bit recycling
  event.jai              -- epoll wrapper, stale event detection
  router.jai             -- Router, dispatch, middleware chains, #add_context
  helpers.jai            -- Response helpers, URL decode, query/form/multipart parsing
  server.jai             -- Worker threads, SO_REUSEPORT, event loop
```

## License

MIT
