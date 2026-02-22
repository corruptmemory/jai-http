
// -- Single-threaded tests --

test_init_destroy :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);
    assert(ch.items.count == 4, "Capacity should be 4, got %", ch.items.count);
    assert(ch.head == 0);
    assert(ch.tail == 0);
    assert(!ch.closed);
    print("  PASS: test_init_destroy\n");
}

test_send_receive_single :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);
    send(*ch, 42);
    value, ok := receive(*ch);
    assert(ok, "receive should return ok=true");
    assert(value == 42, "Expected 42, got %", value);
    print("  PASS: test_send_receive_single\n");
}

test_fifo_ordering :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);
    send(*ch, 10);
    send(*ch, 20);
    send(*ch, 30);
    v1, ok1 := receive(*ch);
    v2, ok2 := receive(*ch);
    v3, ok3 := receive(*ch);
    assert(ok1 && ok2 && ok3, "All receives should succeed");
    assert(v1 == 10, "First should be 10, got %", v1);
    assert(v2 == 20, "Second should be 20, got %", v2);
    assert(v3 == 30, "Third should be 30, got %", v3);
    print("  PASS: test_fifo_ordering\n");
}

test_fill_to_capacity :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);
    for i: 0..3 send(*ch, i * 10);
    for i: 0..3 {
        value, ok := receive(*ch);
        assert(ok);
        assert(value == i * 10, "Expected %, got %", i * 10, value);
    }
    print("  PASS: test_fill_to_capacity\n");
}

test_wraparound :: () {
    ch: Channel(int);
    init(*ch, 2);
    defer destroy(*ch);
    for i: 0..9 {
        send(*ch, i);
        value, ok := receive(*ch);
        assert(ok);
        assert(value == i, "Iteration %: expected %, got %", i, i, value);
    }
    print("  PASS: test_wraparound\n");
}

test_item_padding :: () {
    Small :: struct { x: u8; }
    padding := Channel(Small).Item.PADDING_SIZE;
    item_size := size_of(Channel(Small).Item);
    assert(item_size % 64 == 0, "Item should be cache-line aligned, size=%", item_size);
    assert(padding > 0, "Small struct should have padding, got %", padding);
    print("  PASS: test_item_padding\n");
}

// -- Multi-threaded tests --

Producer_Ctx :: struct {
    ch: *Channel(int);
    count: int;
}

producer_proc :: (thread: *Thread) -> s64 {
    ctx := cast(*Producer_Ctx) thread.data;
    for i: 0..ctx.count-1 send(ctx.ch, i);
    return 0;
}

test_producer_consumer :: () {
    COUNT :: 1000;
    ch: Channel(int);
    init(*ch, 16);
    defer destroy(*ch);

    ctx: Producer_Ctx;
    ctx.ch = *ch;
    ctx.count = COUNT;

    t: Thread;
    thread_init(*t, producer_proc);
    t.data = *ctx;
    thread_start(*t);

    for i: 0..COUNT-1 {
        value, ok := receive(*ch);
        assert(ok, "receive should succeed for item %", i);
        assert(value == i, "Expected %, got %", i, value);
    }

    thread_is_done(*t, -1);
    thread_deinit(*t);
    print("  PASS: test_producer_consumer\n");
}

Multi_Producer_Ctx :: struct {
    ch:         *Channel(int);
    thread_id:  int;
    per_thread: int;
}

multi_producer_proc :: (thread: *Thread) -> s64 {
    ctx := cast(*Multi_Producer_Ctx) thread.data;
    base := ctx.thread_id * 10000;
    for i: 0..ctx.per_thread-1 send(ctx.ch, base + i);
    return 0;
}

test_multiple_producers :: () {
    NUM_THREADS :: 4;
    PER_THREAD  :: 250;
    TOTAL       :: NUM_THREADS * PER_THREAD;

    ch: Channel(int);
    init(*ch, 32);
    defer destroy(*ch);

    ctxs: [NUM_THREADS] Multi_Producer_Ctx;
    threads: [NUM_THREADS] Thread;
    for i: 0..NUM_THREADS-1 {
        ctxs[i].ch = *ch;
        ctxs[i].thread_id = i;
        ctxs[i].per_thread = PER_THREAD;
        thread_init(*threads[i], multi_producer_proc);
        threads[i].data = *ctxs[i];
        thread_start(*threads[i]);
    }

    received: [NUM_THREADS] int;  // count per thread
    for i: 0..TOTAL-1 {
        value, ok := receive(*ch);
        assert(ok, "receive should succeed for item %", i);
        thread_id := value / 10000;
        assert(thread_id >= 0 && thread_id < NUM_THREADS, "Invalid thread_id % from value %", thread_id, value);
        received[thread_id] += 1;
    }
    for i: 0..NUM_THREADS-1 {
        assert(received[i] == PER_THREAD, "Thread % sent % items, expected %", i, received[i], PER_THREAD);
    }

    for i: 0..NUM_THREADS-1 {
        thread_is_done(*threads[i], -1);
        thread_deinit(*threads[i]);
    }
    print("  PASS: test_multiple_producers\n");
}

Blocking_Recv_Ctx :: struct {
    ch:    *Channel(int);
    value: int;
    ok:    bool;
    done:  bool;
}

blocking_recv_proc :: (thread: *Thread) -> s64 {
    ctx := cast(*Blocking_Recv_Ctx) thread.data;
    ctx.value, ctx.ok = receive(ctx.ch);
    ctx.done = true;
    return 0;
}

test_blocking_receive :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);

    ctx: Blocking_Recv_Ctx;
    ctx.ch = *ch;

    t: Thread;
    thread_init(*t, blocking_recv_proc);
    t.data = *ctx;
    thread_start(*t);

    sleep_milliseconds(50);
    assert(!ctx.done, "Consumer should be blocked");
    send(*ch, 99);

    thread_is_done(*t, -1);
    thread_deinit(*t);
    assert(ctx.done, "Consumer should have finished");
    assert(ctx.ok, "receive should return ok=true");
    assert(ctx.value == 99, "Expected 99, got %", ctx.value);
    print("  PASS: test_blocking_receive\n");
}

Blocking_Send_Ctx :: struct {
    ch:   *Channel(int);
    done: bool;
}

blocking_send_proc :: (thread: *Thread) -> s64 {
    ctx := cast(*Blocking_Send_Ctx) thread.data;
    send(ctx.ch, 77);
    ctx.done = true;
    return 0;
}

test_blocking_send :: () {
    ch: Channel(int);
    init(*ch, 1);
    defer destroy(*ch);
    send(*ch, 11);  // fill buffer

    ctx: Blocking_Send_Ctx;
    ctx.ch = *ch;

    t: Thread;
    thread_init(*t, blocking_send_proc);
    t.data = *ctx;
    thread_start(*t);

    sleep_milliseconds(50);
    assert(!ctx.done, "Producer should be blocked");
    value, ok := receive(*ch);  // drain one to unblock
    assert(ok && value == 11);

    thread_is_done(*t, -1);
    thread_deinit(*t);
    assert(ctx.done, "Producer should have finished");
    // The producer's item (77) should now be in the channel
    value2, ok2 := receive(*ch);
    assert(ok2 && value2 == 77, "Expected 77, got %", value2);
    print("  PASS: test_blocking_send\n");
}

// -- Close behavior tests --

Close_Recv_Ctx :: struct {
    ch:    *Channel(int);
    value: int;
    ok:    bool;
    done:  bool;
}

close_recv_proc :: (thread: *Thread) -> s64 {
    ctx := cast(*Close_Recv_Ctx) thread.data;
    ctx.value, ctx.ok = receive(ctx.ch);
    ctx.done = true;
    return 0;
}

test_close_unblocks_receiver :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);

    ctx: Close_Recv_Ctx;
    ctx.ch = *ch;

    t: Thread;
    thread_init(*t, close_recv_proc);
    t.data = *ctx;
    thread_start(*t);

    sleep_milliseconds(50);
    assert(!ctx.done, "Consumer should be blocked on empty channel");
    close(*ch);

    thread_is_done(*t, -1);
    thread_deinit(*t);
    assert(ctx.done, "Consumer should have finished");
    assert(!ctx.ok, "receive should return ok=false after close");
    print("  PASS: test_close_unblocks_receiver\n");
}

Close_Send_Ctx :: struct {
    ch:   *Channel(int);
    done: bool;
}

close_send_proc :: (thread: *Thread) -> s64 {
    ctx := cast(*Close_Send_Ctx) thread.data;
    send(ctx.ch, 55);
    ctx.done = true;
    return 0;
}

test_close_unblocks_sender :: () {
    ch: Channel(int);
    init(*ch, 1);
    defer destroy(*ch);
    send(*ch, 11);  // fill buffer

    ctx: Close_Send_Ctx;
    ctx.ch = *ch;

    t: Thread;
    thread_init(*t, close_send_proc);
    t.data = *ctx;
    thread_start(*t);

    sleep_milliseconds(50);
    assert(!ctx.done, "Producer should be blocked on full channel");
    close(*ch);

    thread_is_done(*t, -1);
    thread_deinit(*t);
    assert(ctx.done, "Producer should have finished after close");
    print("  PASS: test_close_unblocks_sender\n");
}

test_close_drains_buffer :: () {
    ch: Channel(int);
    init(*ch, 8);
    defer destroy(*ch);
    send(*ch, 1);
    send(*ch, 2);
    send(*ch, 3);
    close(*ch);

    v1, ok1 := receive(*ch);
    v2, ok2 := receive(*ch);
    v3, ok3 := receive(*ch);
    assert(ok1 && v1 == 1, "Should drain first item");
    assert(ok2 && v2 == 2, "Should drain second item");
    assert(ok3 && v3 == 3, "Should drain third item");

    _, ok4 := receive(*ch);
    assert(!ok4, "Should return ok=false when closed and empty");
    print("  PASS: test_close_drains_buffer\n");
}

test_send_after_close :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);
    close(*ch);
    send(*ch, 99);  // should be a no-op
    _, ok := receive(*ch);
    assert(!ok, "No items should be in channel after send-on-closed");
    print("  PASS: test_send_after_close\n");
}

test_receive_on_closed_empty :: () {
    ch: Channel(int);
    init(*ch, 4);
    defer destroy(*ch);
    close(*ch);
    _, ok := receive(*ch);
    assert(!ok, "receive on closed empty channel should return ok=false");
    print("  PASS: test_receive_on_closed_empty\n");
}

// -- Main --

main :: () {
    print("Running channel tests...\n\n");

    print("init/destroy:\n");
    test_init_destroy();

    print("\nsend/receive:\n");
    test_send_receive_single();
    test_fifo_ordering();
    test_fill_to_capacity();
    test_wraparound();
    test_item_padding();

    print("\nmulti-threaded:\n");
    test_producer_consumer();
    test_multiple_producers();
    test_blocking_receive();
    test_blocking_send();

    print("\nclose behavior:\n");
    test_close_unblocks_receiver();
    test_close_unblocks_sender();
    test_close_drains_buffer();
    test_send_after_close();
    test_receive_on_closed_empty();

    print("\nAll channel tests passed.\n");
}

#import "Basic";
#import "Thread";
#import "channel";
