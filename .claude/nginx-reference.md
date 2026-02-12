# nginx Internals Reference

Architecture cheat-sheet for nginx internals, distilled from the source at `~/projects/nginx/`. Focused on patterns relevant to building a high-performance HTTP server in Jai.

**Source layout:** `src/core/` (data structures, connections, pools), `src/event/` (event loop, epoll, timers, posted events), `src/os/unix/` (process model, I/O), `src/http/` (HTTP layer).

---

## 1. Process Model

nginx uses a **master-worker** process architecture (not threads).

- **Master** (`ngx_master_process_cycle`): forks N workers, handles signals, does no I/O
- **Workers** (`ngx_worker_process_cycle`): each runs an independent event loop, handles all connections assigned to it
- Workers are forked via `ngx_spawn_process(cycle, ngx_worker_process_cycle, (void*)(intptr_t)i, ...)`
- Each worker stores its index in global `ngx_worker`

### Worker Lifecycle
```
ngx_worker_process_cycle(cycle, data):
    worker = (intptr_t) data
    ngx_worker_process_init(cycle, worker)   // per-worker setup
    for (;;):
        ngx_process_events_and_timers(cycle) // THE event loop
        // handle signals: terminate, quit, reopen
```

### Per-Worker Init (`ngx_worker_process_init`)
1. Set CPU affinity, rlimits, priority, user/group
2. Call `init_process` for every module — this triggers `ngx_event_process_init()`
3. Close other workers' socketpair channels

---

## 2. Connection & Event Pre-allocation

**Key insight:** All connections and events are allocated ONCE at worker startup as three parallel flat arrays. No per-connection malloc in the hot path.

### Pre-allocation (`ngx_event_process_init`, lines 754-801)
```c
// Three parallel arrays, indexed the same way:
cycle->connections  = ngx_alloc(sizeof(ngx_connection_t) * connection_n)
cycle->read_events  = ngx_alloc(sizeof(ngx_event_t) * connection_n)
cycle->write_events = ngx_alloc(sizeof(ngx_event_t) * connection_n)

// Wire them together:
c[i].read  = &read_events[i]
c[i].write = &write_events[i]
c[i].fd    = -1
```

### Free List (Singly-Linked Stack via `c->data`)
```c
// Built by walking array backwards:
c[i].data = next;  next = &c[i];
cycle->free_connections = next;

// Pop from free list:
c = cycle->free_connections;
cycle->free_connections = c->data;   // c->data doubles as next pointer

// Push back:
c->data = cycle->free_connections;
cycle->free_connections = c;
```

### ngx_connection_t (key fields)
```c
struct ngx_connection_s {
    void               *data;          // free list next ptr, OR request ptr when in use
    ngx_event_t        *read;          // pointer into read_events array
    ngx_event_t        *write;         // pointer into write_events array
    ngx_socket_t        fd;

    ngx_recv_pt         recv;          // function pointers for I/O
    ngx_send_pt         send;
    ngx_recv_chain_pt   recv_chain;
    ngx_send_chain_pt   send_chain;

    ngx_listening_t    *listening;     // which listener accepted this
    ngx_pool_t         *pool;          // per-connection memory pool
    ngx_buf_t          *buffer;        // pre-read buffer

    ngx_queue_t         queue;         // for reusable connections queue
    ngx_atomic_uint_t   number;        // unique connection counter

    unsigned            reusable:1;    // in reusable queue (keepalive idle)
    unsigned            close:1;       // marked for closing
    unsigned            idle:1;
    unsigned            sendfile:1;
    unsigned            tcp_nodelay:2;
    unsigned            tcp_nopush:2;
};
```

### ngx_event_t (key fields)
```c
struct ngx_event_s {
    void            *data;             // back-pointer to connection

    unsigned         write:1;          // 0=read event, 1=write event
    unsigned         accept:1;         // this is a listening socket accept event
    unsigned         instance:1;       // stale event detection bit (flips each reuse)
    unsigned         active:1;         // registered with epoll
    unsigned         ready:1;          // I/O is ready (set by epoll handler)
    unsigned         eof:1;
    unsigned         error:1;
    unsigned         timedout:1;
    unsigned         timer_set:1;
    unsigned         posted:1;         // in a posted event queue

    int              available;        // bytes available, or -1 if unknown

    ngx_event_handler_pt  handler;     // THE callback — called when event fires

    ngx_rbtree_node_t     timer;       // embedded node for timer rbtree
    ngx_queue_t           queue;       // embedded node for posted event queues
};
```

**Relationship:** `event->data` points to `connection`, `connection->read`/`->write` point to events. All cross-linked at init.

---

## 3. SO_REUSEPORT & Listening Socket Cloning

**Key insight:** With SO_REUSEPORT, each worker gets its **own** listening socket. The kernel load-balances incoming connections across them. Zero cross-worker contention.

### Flow
1. **Config phase** (`ngx_event_init_conf`): For each listening socket with `reuseport` flag, call `ngx_clone_listening()` which duplicates the `ngx_listening_t` entry N-1 times (one per additional worker), setting `ls->worker = n`

2. **Socket creation** (`ngx_open_listening_sockets`): Each cloned entry gets its own `socket()` + `setsockopt(SO_REUSEPORT)` + `bind()` + `listen()`

3. **Per-worker epoll registration** (`ngx_event_process_init`): Each worker only registers the listening socket where `ls[i].worker == ngx_worker`:
```c
if (ls[i].reuseport && ls[i].worker != ngx_worker) continue;
```

### Without SO_REUSEPORT (legacy)
Workers share a single listening fd. Two strategies:
- **Accept mutex** (`ngx_use_accept_mutex`): Only one worker at a time has the listen fd in its epoll. Workers take turns via shared memory mutex.
- **EPOLLEXCLUSIVE** (`ngx_use_exclusive_accept`): All workers register the fd, kernel wakes only one.

---

## 4. Epoll Implementation

File: `src/event/modules/ngx_epoll_module.c`

### Module-Level State
```c
static int                  ep = -1;         // epoll fd (per-worker, inherited across forks but re-created)
static struct epoll_event  *event_list;      // array for epoll_wait results
static ngx_uint_t           nevents;         // size of event_list (default 512)
```

### Init (`ngx_epoll_init`)
```c
ep = epoll_create(connection_n / 2);
event_list = ngx_alloc(sizeof(struct epoll_event) * events);
ngx_event_flags = NGX_USE_CLEAR_EVENT | NGX_USE_GREEDY_EVENT | NGX_USE_EPOLL_EVENT;
// NGX_USE_CLEAR_EVENT = EPOLLET (edge-triggered)
// NGX_USE_GREEDY_EVENT = must drain until EAGAIN
```

### The Instance Bit Trick (Stale Event Detection)

**Problem:** After closing fd A and opening fd B that reuses the same fd number, stale epoll events for A could fire and be misinterpreted as events for B.

**Solution:** Pack connection pointer + 1-bit instance flag into `epoll_data.ptr`:
```c
// When registering:
ee.data.ptr = (void *) ((uintptr_t) c | ev->instance);

// When processing events:
c = event_list[i].data.ptr;
instance = (uintptr_t) c & 1;                    // extract bit
c = (ngx_connection_t *) ((uintptr_t) c & ~1);   // clear bit to get real pointer
if (c->fd == -1 || rev->instance != instance) {
    continue;  // STALE — skip
}
```

**Instance bit lifecycle:** When `ngx_get_connection()` reuses a connection slot, it **flips** the instance bit:
```c
instance = rev->instance;
ngx_memzero(rev, sizeof(ngx_event_t));
rev->instance = !instance;   // flip!
```
So any pending epoll events from the old connection will have the old instance bit value, which won't match.

### Add/Delete Events
```c
ngx_epoll_add_event(ev, event, flags):
    // If the OTHER event on same connection is active → EPOLL_CTL_MOD (both events)
    // Otherwise → EPOLL_CTL_ADD
    if (e->active) { op = EPOLL_CTL_MOD; events |= prev; }
    else            { op = EPOLL_CTL_ADD; }
    ee.data.ptr = (void *) ((uintptr_t) c | ev->instance);
    epoll_ctl(ep, op, c->fd, &ee);

ngx_epoll_add_connection(c):
    // Register BOTH read+write at once with edge-triggered:
    ee.events = EPOLLIN|EPOLLOUT|EPOLLET|EPOLLRDHUP;
    epoll_ctl(ep, EPOLL_CTL_ADD, c->fd, &ee);
```

**On close:** No explicit `epoll_ctl(DEL)` needed — kernel auto-removes on fd close. nginx uses `NGX_CLOSE_EVENT` flag to skip the syscall.

### Process Events (`ngx_epoll_process_events`)
```c
events = epoll_wait(ep, event_list, nevents, timer);

for each event:
    extract connection pointer and instance bit
    if stale (fd==-1 or instance mismatch): skip

    if (EPOLLIN && rev->active):
        rev->ready = 1
        if NGX_POST_EVENTS:
            post to accept_events or posted_events queue
        else:
            rev->handler(rev)     // call directly

    if (EPOLLOUT && wev->active):
        wev->ready = 1
        if NGX_POST_EVENTS:
            post to posted_events queue
        else:
            wev->handler(wev)
```

---

## 5. The Main Event Loop

`ngx_process_events_and_timers(cycle)` — called in a tight `for(;;)` by each worker:

```
1. Determine timer:
   - If timer_resolution set: timer = INFINITE (rely on SIGALRM)
   - Otherwise: timer = time until next rbtree timer expires

2. Accept mutex handling (if enabled):
   - Try to acquire accept mutex
   - If held: set NGX_POST_EVENTS flag (defer event handling)
   - If not held: limit timer to accept_mutex_delay

3. Move any "posted next" events to regular posted queue

4. === epoll_wait(timer) ===
   ngx_process_events(cycle, timer, flags)

5. Process posted accept events FIRST (priority):
   ngx_event_process_posted(cycle, &ngx_posted_accept_events)

6. Release accept mutex (if held)

7. Expire timers:
   ngx_event_expire_timers()

8. Process regular posted events:
   ngx_event_process_posted(cycle, &ngx_posted_events)
```

**Why post events?** When holding the accept mutex, you want to process accept events and release the mutex ASAP, before doing potentially slow work on regular events. The NGX_POST_EVENTS flag makes epoll_wait queue events instead of calling handlers directly.

---

## 6. Posted Events

Three queues (doubly-linked intrusive lists using `ngx_queue_t`):

| Queue | Purpose |
|---|---|
| `ngx_posted_accept_events` | Accept events — processed first, before mutex release |
| `ngx_posted_events` | Regular read/write events — processed after mutex release |
| `ngx_posted_next_events` | Events deferred to next event loop iteration |

```c
// Post an event:
ngx_post_event(ev, queue):
    if (!ev->posted):
        ev->posted = 1
        ngx_queue_insert_tail(queue, &ev->queue)

// Delete:
ngx_delete_posted_event(ev):
    ev->posted = 0
    ngx_queue_remove(&ev->queue)

// Process all events in a queue:
ngx_event_process_posted(cycle, posted):
    while !ngx_queue_empty(posted):
        q = ngx_queue_head(posted)
        ev = ngx_queue_data(q, ngx_event_t, queue)
        ngx_delete_posted_event(ev)
        ev->handler(ev)
```

---

## 7. Timer Mechanism

Uses a **red-black tree** (`ngx_event_timer_rbtree`) with the timer's expiry time as the key.

```c
// Add timer (absolute time = now + ms):
ngx_event_add_timer(ev, timer):
    key = ngx_current_msec + timer
    // Optimization: if existing timer is within 300ms, skip update
    if (ev->timer_set && abs(key - ev->timer.key) < NGX_TIMER_LAZY_DELAY): return
    ev->timer.key = key
    ngx_rbtree_insert(&ngx_event_timer_rbtree, &ev->timer)
    ev->timer_set = 1

// Find earliest timer (for epoll_wait timeout):
ngx_event_find_timer():
    node = ngx_rbtree_min(root, sentinel)
    return node->key - ngx_current_msec   // ms until next expiry

// Expire all timers that have passed:
ngx_event_expire_timers():
    loop:
        node = ngx_rbtree_min(root)
        if (node->key - ngx_current_msec > 0): break  // not expired yet
        ev->timedout = 1
        ev->handler(ev)
```

**NGX_TIMER_LAZY_DELAY (300ms):** If a timer already exists and the new timeout is within 300ms of the old value, skip the rbtree operation. This minimizes rbtree churn for fast connections that repeatedly reset their timeout.

---

## 8. Memory Pools (`ngx_pool_t`)

Slab-style bump allocator with cleanup handler support. Key to nginx's zero-per-request-malloc design.

### Structure
```c
ngx_pool_data_t {
    u_char      *last;      // next free byte (bump pointer)
    u_char      *end;       // end of this block
    ngx_pool_t  *next;      // linked list of blocks
    ngx_uint_t   failed;    // allocation failures on this block
}

ngx_pool_s {
    ngx_pool_data_t    d;          // inline first block
    size_t             max;        // max small alloc size (~4095)
    ngx_pool_t        *current;    // skip to block with space
    ngx_chain_t       *chain;      // free chain links cache
    ngx_pool_large_t  *large;      // linked list of large allocs
    ngx_pool_cleanup_t *cleanup;   // cleanup handlers
    ngx_log_t          *log;
}
```

### Allocation Strategy
```
ngx_palloc(pool, size):
    if size <= pool->max:
        // SMALL: bump pointer from current block
        // If current block full, allocate new block (same size as first)
        // After 4 failures on a block, advance pool->current past it
    else:
        // LARGE: malloc + track in pool->large linked list
        // Reuse up to 3 freed large slots before allocating new tracker
```

### Key Functions
- `ngx_create_pool(size, log)` — create pool, default 16KB
- `ngx_destroy_pool(pool)` — run cleanups, free all large allocs, free all blocks
- `ngx_reset_pool(pool)` — free large allocs, reset bump pointers (keep blocks)
- `ngx_palloc(pool, size)` — aligned allocation
- `ngx_pnalloc(pool, size)` — unaligned (faster, no padding)
- `ngx_pcalloc(pool, size)` — zeroed allocation
- `ngx_pfree(pool, p)` — free a LARGE allocation only (small allocs can't be individually freed)
- `ngx_pool_cleanup_add(pool, size)` — register cleanup handler (called on pool destroy)

### Usage Pattern
```
Per-connection: c->pool = ngx_create_pool(ls->pool_size, log)
Per-request: r->pool = ngx_create_pool(...)
On close: ngx_destroy_pool(c->pool) — frees everything at once
```

---

## 9. Buffer Chains

### ngx_buf_t — The Buffer
```c
struct ngx_buf_s {
    // Memory buffer region:
    u_char  *pos;        // current read position
    u_char  *last;       // end of valid data
    u_char  *start;      // start of allocated buffer
    u_char  *end;        // end of allocated buffer

    // File region (for sendfile):
    off_t    file_pos;
    off_t    file_last;
    ngx_file_t *file;

    // Flags:
    unsigned temporary:1;     // data can be modified
    unsigned memory:1;        // read-only memory
    unsigned in_file:1;       // data is in file
    unsigned flush:1;         // flush signal
    unsigned last_buf:1;      // last buffer in response
    unsigned last_in_chain:1; // last in current chain
};
```

**Data region:** `pos..last` (valid data), `start..end` (allocated buffer). As data is consumed, `pos` advances toward `last`.

### ngx_chain_t — Linked List of Buffers
```c
struct ngx_chain_s {
    ngx_buf_t    *buf;
    ngx_chain_t  *next;
};
```

**Usage:** Response bodies are chains of buffers. Can mix memory buffers and file regions (for sendfile). `ngx_chain_update_sent(chain, sent)` advances past sent bytes for partial writes.

**Free chain links:** `ngx_free_chain(pool, cl)` pushes to `pool->chain` for reuse. `ngx_alloc_chain_link(pool)` pops from there first.

---

## 10. Intrusive Queue (`ngx_queue_t`)

Doubly-linked circular list. The node is **embedded in the containing struct** (no separate allocation).

```c
struct ngx_queue_s {
    ngx_queue_t  *prev;
    ngx_queue_t  *next;
};
```

### Operations
```c
ngx_queue_init(q)              // self-referential: q->prev = q->next = q
ngx_queue_empty(h)             // h == h->prev
ngx_queue_insert_head(h, x)   // insert after sentinel
ngx_queue_insert_tail(h, x)   // insert before sentinel
ngx_queue_remove(x)           // unlink node
ngx_queue_head(h)              // h->next
ngx_queue_last(h)              // h->prev
ngx_queue_sentinel(h)          // h itself
ngx_queue_data(q, type, link)  // container_of: get struct from embedded queue node
```

**Used for:** posted events (`ev->queue`), reusable connections (`c->queue`), free chain links.

---

## 11. Chunked List (`ngx_list_t`)

Array-of-arrays for headers. Each part has `nalloc` slots; when full, a new part is allocated from the pool.

```c
ngx_list_part_s { void *elts; ngx_uint_t nelts; ngx_list_part_t *next; }
ngx_list_t { ngx_list_part_t *last; ngx_list_part_t part; size_t size; ngx_uint_t nalloc; ngx_pool_t *pool; }
```

---

## 12. Accept Path

`ngx_event_accept(ev)` — called when listening socket is readable:

```
1. Loop (multi_accept: keep accepting until EAGAIN):
    s = accept4(lc->fd, &sa, &socklen, SOCK_NONBLOCK)

2. Backpressure:
    ngx_accept_disabled = connection_n/8 - free_connection_n
    // Positive → this worker is overloaded, skip accept next iteration

3. Get connection from free list:
    c = ngx_get_connection(s, log)
    // Pops from free list, flips instance bit, wires read/write events

4. Create per-connection pool:
    c->pool = ngx_create_pool(ls->pool_size, log)

5. Set up I/O function pointers:
    c->recv = ngx_recv; c->send = ngx_send;
    c->recv_chain = ngx_recv_chain; c->send_chain = ngx_send_chain;

6. Mark write event ready (can write immediately after accept):
    wev->ready = 1

7. Call the listener's handler:
    ls->handler(c)   // For HTTP: ngx_http_init_connection
```

---

## 13. HTTP Connection Init

`ngx_http_init_connection(c)` (set as `ls->handler` during HTTP config):
- Sets `c->read->handler = ngx_http_wait_request_handler`
- Adds read timer for `client_header_timeout`
- Registers connection with epoll for reading
- On first data: allocates request, starts HTTP parsing

---

## 14. I/O Function Pointers

Each connection has pluggable I/O via function pointers set at accept time:

```c
// Set from ngx_os_io (platform-specific):
c->recv       = ngx_unix_recv         // read() with EAGAIN handling
c->send       = ngx_unix_send         // write() with EAGAIN handling
c->recv_chain = ngx_readv_chain       // readv() scatter I/O
c->send_chain = ngx_linux_sendfile_chain  // writev() + sendfile()
```

`ngx_linux_sendfile_chain` is the key write path: builds iovec from buffer chain, uses `writev()` for memory buffers, `sendfile()` for file buffers. Handles partial writes by advancing the chain.

---

## 15. Key Constants & Defaults

| Constant | Value | Meaning |
|---|---|---|
| `DEFAULT_CONNECTIONS` | 512 | Default worker_connections |
| `NGX_DEFAULT_POOL_SIZE` | 16384 | Default pool size (16KB) |
| `NGX_MAX_ALLOC_FROM_POOL` | 4095 | Max small allocation (pagesize-1) |
| `NGX_POOL_ALIGNMENT` | 16 | Pool alignment |
| `NGX_TIMER_LAZY_DELAY` | 300 | Timer update skip threshold (ms) |
| `NGX_TIMER_INFINITE` | (ngx_msec_t)-1 | No timeout (block indefinitely) |
| `NGX_INVALID_INDEX` | 0xd0d0d0d0 | Sentinel for event index |

---

## 16. Patterns to Replicate in Jai

### Must-Have for Performance Parity
1. **Per-worker epoll fd** — each thread creates its own `epoll_create()`, no shared epoll
2. **SO_REUSEPORT** — each thread does its own `socket()`+`bind()`+`listen()`, kernel distributes
3. **Pre-allocated connection/event arrays** — `alloc` once at startup, free-list stack for O(1) get/put
4. **Instance bit for stale events** — pack in pointer LSB, flip on connection reuse
5. **Edge-triggered (EPOLLET)** — must drain until EAGAIN, avoids repeated wakeups
6. **Zero cross-thread communication** — each worker is fully independent in the hot path

### Should-Have
7. **Pool allocator per connection** — bump allocator, bulk destroy on close (maps to Jai's `push_context` with pool allocator)
8. **Posted event queues** — defer handler execution out of epoll processing for better batching
9. **Timer rbtree with lazy update** — skip rbtree ops if timer delta < 300ms
10. **accept4(SOCK_NONBLOCK)** — avoid separate fcntl
11. **multi_accept** — drain accept queue in one go
12. **Buffer chains** — writev/sendfile for zero-copy output

### Can Skip (nginx-specific complexity)
- Accept mutex (only needed without SO_REUSEPORT)
- EPOLLEXCLUSIVE (only without SO_REUSEPORT)
- Master-worker fork model (using threads instead)
- Hot binary upgrade / graceful reload
- Shared memory zones for stats
