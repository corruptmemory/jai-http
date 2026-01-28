#import "http_server";

main :: () {
    server :Server; //:= New(Server);
    // defer free(server);
    init_server(*server, backlog_size = 2048);
    listen(*server, "0.0.0.0", 8080);
    thread_deinit(*server.listening_thread);
}


#import "Basic";
#import "Thread";
#import "Socket";
