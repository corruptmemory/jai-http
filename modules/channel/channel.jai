
Channel :: struct(T: Type) {
    Item :: struct {
        value: T;
        BASE_SIZE    :: size_of(T);
        PADDING_SIZE :: #run align_forward(BASE_SIZE, CACHE_LINE_SIZE) - BASE_SIZE;
        padding: [PADDING_SIZE] u8;
    }
    data_to_free: *void;
    items:        [] Item;
    head:         int;
    tail:         int;
    lock:         Mutex;
    read_cond:    Condition_Variable;
    write_cond:   Condition_Variable;
    closed:       bool;
}

destroy :: (using channel: *Channel($T)) {
    assert(data_to_free != null);
    free(data_to_free);
    data_to_free = null;
    destroy(*lock);
    destroy(*read_cond);
    destroy(*write_cond);
}

init :: (using channel: *Channel($T), count: int) {
    assert(count > 0);
    items, data_to_free = NewArray(count, Channel(T).Item, true);
    init(*lock);
    init(*read_cond);
    init(*write_cond);
}

close :: (channel: *Channel($T)) {
    lock(*channel.lock);
    channel.closed = true;
    unlock(*channel.lock);
    wake_all(*channel.read_cond);
    wake_all(*channel.write_cond);
}

send :: (channel: *Channel($T), item: T) {
    defer unlock(*channel.lock);
    defer wake(*channel.read_cond);
    lock(*channel.lock);

    if channel.closed return;
    while !channel.closed && channel.tail - channel.head == channel.items.count {
        wait(*channel.write_cond, *channel.lock);
    }
    if channel.closed return;
    channel.items[channel.tail % channel.items.count].value = item;
    channel.tail += 1;
}

receive :: (channel: *Channel($T)) -> (value: T, ok: bool) {
    defer unlock(*channel.lock);
    defer wake(*channel.write_cond);
    lock(*channel.lock);

    while channel.head == channel.tail {
        if channel.closed { empty: T; return empty, false; }
        wait(*channel.read_cond, *channel.lock);
    }
    item := channel.items[channel.head];
    channel.head += 1;
    if channel.head >= channel.items.count {
        channel.head -= channel.items.count;
        channel.tail -= channel.items.count;
    }
    return item.value, true;
}
