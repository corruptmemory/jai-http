
test_parse_request_line :: () {
    SAMPLE_REQUEST_LINE :: "POST /foo HTTP/1.1\r\n";
    req: Request;
    ok, rem := parse_request_line(xx SAMPLE_REQUEST_LINE, *req);
    if !ok {
        log_error("!!! Failed to parse request line");
    }
    print("%\n", req);
    print("%\n", cast(string) req.request_line_raw);
}

main :: () {
    test_parse_request_line();
}

#import "Basic";
#import "http_server";
