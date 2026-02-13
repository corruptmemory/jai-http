
#module_parameters (
    CACHE_LINE_SIZE     : s32 = 64,
    READ_BUFFER_SIZE    : s32 = 4096,
    MAX_HEADERS         : s32 = 64,
    MAX_ROUTES          : s32 = 128,
    MAX_PARAMS          : s32 = 8,
    MAX_MIDDLEWARE      : s32 = 16,
    MAX_MOUNTS          : s32 = 16,
    MAX_FORM_VALUES     : s32 = 64,
    MAX_MULTIPART_PARTS : s32 = 16,
	LISTEN_BACKLOG      : s32 = 1024
);

#scope_module
Basic :: #import "Basic";
Pool_Module :: #import "Pool";

#import "POSIX";
#import "Linux";
#import "Socket";
#import "Thread";

#load "http.jai";
#load "connection.jai";
#load "event.jai";
#load "router.jai";
#load "helpers.jai";
#load "server.jai";
