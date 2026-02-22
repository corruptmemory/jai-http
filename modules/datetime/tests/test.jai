
// -- parse_rfc3339 tests --

test_parse_rfc3339_basic :: () {
    t, ok := parse_rfc3339("2026-02-11T20:56:32Z");
    assert(ok, "Should parse standard RFC3339");
    ct := to_calendar(t, .UTC);
    assert(ct.year == 2026, "Year should be 2026, got %", ct.year);
    assert(ct.month_starting_at_0 == 1, "Month should be 1 (Feb), got %", ct.month_starting_at_0);
    assert(ct.day_of_month_starting_at_0 == 10, "Day should be 10 (11th), got %", ct.day_of_month_starting_at_0);
    assert(ct.hour == 20, "Hour should be 20, got %", ct.hour);
    assert(ct.minute == 56, "Minute should be 56, got %", ct.minute);
    assert(ct.second == 32, "Second should be 32, got %", ct.second);
    print("  PASS: test_parse_rfc3339_basic\n");
}

test_parse_rfc3339_plus_separator :: () {
    t, ok := parse_rfc3339("2026-02-11+20:56:32");
    assert(ok, "Should parse AmbientWeather quirk with + separator");
    ct := to_calendar(t, .UTC);
    assert(ct.year == 2026);
    assert(ct.month_starting_at_0 == 1);
    assert(ct.day_of_month_starting_at_0 == 10);
    assert(ct.hour == 20);
    assert(ct.minute == 56);
    assert(ct.second == 32);
    print("  PASS: test_parse_rfc3339_plus_separator\n");
}

test_parse_rfc3339_midnight :: () {
    t, ok := parse_rfc3339("2026-01-01T00:00:00Z");
    assert(ok, "Should parse midnight boundary");
    ct := to_calendar(t, .UTC);
    assert(ct.year == 2026);
    assert(ct.month_starting_at_0 == 0, "Month should be 0 (Jan)");
    assert(ct.day_of_month_starting_at_0 == 0, "Day should be 0 (1st)");
    assert(ct.hour == 0);
    assert(ct.minute == 0);
    assert(ct.second == 0);
    print("  PASS: test_parse_rfc3339_midnight\n");
}

test_parse_rfc3339_invalid :: () {
    _, ok := parse_rfc3339("not-a-date");
    assert(!ok, "Should reject garbage input");
    print("  PASS: test_parse_rfc3339_invalid\n");
}

test_parse_rfc3339_short :: () {
    _, ok := parse_rfc3339("2026-02");
    assert(!ok, "Should reject too-short input");
    print("  PASS: test_parse_rfc3339_short\n");
}

test_parse_rfc3339_bad_month :: () {
    _, ok := parse_rfc3339("2026-13-01T00:00:00Z");
    assert(!ok, "Should reject month 13");
    print("  PASS: test_parse_rfc3339_bad_month\n");
}

test_parse_rfc3339_bad_delimiters :: () {
    _, ok := parse_rfc3339("2026/02/11T20:56:32Z");
    assert(!ok, "Should reject / delimiters");
    print("  PASS: test_parse_rfc3339_bad_delimiters\n");
}

// -- format_date tests --

test_format_date_basic :: () {
    t, ok := parse_rfc3339("2026-02-11T20:56:32Z");
    assert(ok);
    result := format_date(t);
    assert(result == "2026-02-11", "Expected '2026-02-11', got '%'", result);
    print("  PASS: test_format_date_basic\n");
}

test_format_date_single_digit_month :: () {
    t, ok := parse_rfc3339("2026-01-05T12:00:00Z");
    assert(ok);
    result := format_date(t);
    assert(result == "2026-01-05", "Expected '2026-01-05', got '%'", result);
    print("  PASS: test_format_date_single_digit_month\n");
}

// -- to_unix / from_unix tests --

test_unix_epoch_zero :: () {
    // 1970-01-01T00:00:00Z should be Unix 0
    t, ok := parse_rfc3339("1970-01-01T00:00:00Z");
    assert(ok, "Should parse epoch");
    unix, u_ok := to_unix(t);
    assert(u_ok, "to_unix should succeed");
    assert(unix == 0, "Unix epoch should be 0, got %", unix);

    // And from_unix(0) should round-trip back
    t2 := from_unix(0);
    ct := to_calendar(t2, .UTC);
    assert(ct.year == 1970);
    assert(ct.month_starting_at_0 == 0);
    assert(ct.day_of_month_starting_at_0 == 0);
    print("  PASS: test_unix_epoch_zero\n");
}

test_unix_roundtrip :: () {
    N :: 1_700_000_000;  // ~2023-11-14
    t := from_unix(N);
    unix, ok := to_unix(t);
    assert(ok);
    assert(unix == N, "Roundtrip should give %, got %", N, unix);
    print("  PASS: test_unix_roundtrip\n");
}

test_to_unix_known :: () {
    // 2026-02-11T20:56:32Z = known Unix timestamp
    // Computed: 1771020992
    t, ok := parse_rfc3339("2026-02-11T20:56:32Z");
    assert(ok);
    unix, u_ok := to_unix(t);
    assert(u_ok);
    assert(unix == 1770843392, "Expected 1770843392, got %", unix);
    print("  PASS: test_to_unix_known\n");
}

// -- start_of_day tests --

test_start_of_day_basic :: () {
    t, ok := parse_rfc3339("2026-02-11T20:56:32Z");
    assert(ok);
    sod := start_of_day(t);
    ct := to_calendar(sod, .UTC);
    assert(ct.year == 2026);
    assert(ct.month_starting_at_0 == 1);
    assert(ct.day_of_month_starting_at_0 == 10);
    assert(ct.hour == 0, "Hour should be 0, got %", ct.hour);
    assert(ct.minute == 0, "Minute should be 0, got %", ct.minute);
    assert(ct.second == 0, "Second should be 0, got %", ct.second);
    print("  PASS: test_start_of_day_basic\n");
}

test_start_of_day_idempotent :: () {
    t, ok := parse_rfc3339("2026-02-11T00:00:00Z");
    assert(ok);
    sod := start_of_day(t);
    unix1, ok1 := to_unix(t);
    unix2, ok2 := to_unix(sod);
    assert(ok1 && ok2);
    assert(unix1 == unix2, "Midnight should be idempotent, got % vs %", unix1, unix2);
    print("  PASS: test_start_of_day_idempotent\n");
}

// -- hours_ago / days_ago tests --

test_hours_ago :: () {
    before := current_time_consensus();
    t := hours_ago(24);
    after := current_time_consensus();

    // t should be approximately 24*3600 seconds before now
    expected_seconds : s64 = 24 * 3600;
    diff_before, _ := to_seconds(before - t);
    diff_after, _  := to_seconds(after - t);

    // The actual offset should be close to expected (within 2s tolerance)
    assert(diff_before >= expected_seconds - 2 && diff_before <= expected_seconds + 2,
        "hours_ago(24) offset from before: %, expected ~%", diff_before, expected_seconds);
    assert(diff_after >= expected_seconds - 2 && diff_after <= expected_seconds + 2,
        "hours_ago(24) offset from after: %, expected ~%", diff_after, expected_seconds);
    print("  PASS: test_hours_ago\n");
}

test_days_ago :: () {
    before := current_time_consensus();
    t := days_ago(7);
    after := current_time_consensus();

    expected_seconds : s64 = 7 * 86400;
    diff_before, _ := to_seconds(before - t);
    diff_after, _  := to_seconds(after - t);

    assert(diff_before >= expected_seconds - 2 && diff_before <= expected_seconds + 2,
        "days_ago(7) offset from before: %, expected ~%", diff_before, expected_seconds);
    assert(diff_after >= expected_seconds - 2 && diff_after <= expected_seconds + 2,
        "days_ago(7) offset from after: %, expected ~%", diff_after, expected_seconds);
    print("  PASS: test_days_ago\n");
}

// -- bucket_start tests --

test_bucket_5min :: () {
    // Unix 1771021000 should floor to 1771020900 (nearest 300s boundary)
    // 1771021000 / 300 = 5903403.33... → floor = 5903403 → 5903403 * 300 = 1771020900
    t := from_unix(1771021000);
    b := bucket_start(t, 300);
    unix, ok := to_unix(b);
    assert(ok);
    assert(unix == 1771020900, "5min bucket: expected 1771020900, got %", unix);
    print("  PASS: test_bucket_5min\n");
}

test_bucket_1hour :: () {
    // Unix 1771021000 should floor to 1771020000 (nearest 3600s boundary)
    // 1771021000 / 3600 = 491950.277... → floor = 491950 → 491950 * 3600 = 1771020000
    t := from_unix(1771021000);
    b := bucket_start(t, 3600);
    unix, ok := to_unix(b);
    assert(ok);
    assert(unix == 1771020000, "1hour bucket: expected 1771020000, got %", unix);
    print("  PASS: test_bucket_1hour\n");
}

test_bucket_aligned :: () {
    // Time exactly on a 300s boundary should return itself
    t := from_unix(1771020900);
    b := bucket_start(t, 300);
    unix, ok := to_unix(b);
    assert(ok);
    assert(unix == 1771020900, "Aligned bucket: expected 1771020900, got %", unix);
    print("  PASS: test_bucket_aligned\n");
}

main :: () {
    print("Running datetime tests...\n\n");

    print("parse_rfc3339:\n");
    test_parse_rfc3339_basic();
    test_parse_rfc3339_plus_separator();
    test_parse_rfc3339_midnight();
    test_parse_rfc3339_invalid();
    test_parse_rfc3339_short();
    test_parse_rfc3339_bad_month();
    test_parse_rfc3339_bad_delimiters();

    print("\nformat_date:\n");
    test_format_date_basic();
    test_format_date_single_digit_month();

    print("\nto_unix / from_unix:\n");
    test_unix_epoch_zero();
    test_unix_roundtrip();
    test_to_unix_known();

    print("\nstart_of_day:\n");
    test_start_of_day_basic();
    test_start_of_day_idempotent();

    print("\nhours_ago / days_ago:\n");
    test_hours_ago();
    test_days_ago();

    print("\nbucket_start:\n");
    test_bucket_5min();
    test_bucket_1hour();
    test_bucket_aligned();

    print("\nAll datetime tests passed.\n");
}

#import "Basic";
#import "datetime";
