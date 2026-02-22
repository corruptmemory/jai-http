
#scope_module
#import "Basic";

#scope_file

parse_digits :: (s: string, offset: s64, count: s64) -> (value: s64, ok: bool) {
    if offset + count > s.count  return 0, false;

    value: s64 = 0;
    for i: 0..count-1 {
        c := s.data[offset + i];
        if c < #char "0" || c > #char "9"  return 0, false;
        value = value * 10 + (c - #char "0");
    }
    return value, true;
}

#scope_export

// Parse RFC3339 timestamp: "2026-02-11T20:56:32Z" (standard)
// or "2026-02-11+20:56:32" (AmbientWeather quirk where + replaces T, no Z suffix).
parse_rfc3339 :: (s: string) -> (time: Apollo_Time, ok: bool) {
    // Minimum length: YYYY-MM-DDThh:mm:ss (19 chars)
    if s.count < 19  return .{}, false;

    // Validate delimiters
    if s.data[4] != #char "-" || s.data[7] != #char "-"  return .{}, false;
    sep := s.data[10];
    if sep != #char "T" && sep != #char "+"  return .{}, false;
    if s.data[13] != #char ":" || s.data[16] != #char ":"  return .{}, false;

    year,  y_ok := parse_digits(s, 0, 4);
    month, m_ok := parse_digits(s, 5, 2);
    day,   d_ok := parse_digits(s, 8, 2);
    hour,  h_ok := parse_digits(s, 11, 2);
    min,   mi_ok := parse_digits(s, 14, 2);
    sec,   s_ok := parse_digits(s, 17, 2);

    if !y_ok || !m_ok || !d_ok || !h_ok || !mi_ok || !s_ok  return .{}, false;

    // Range validation
    if month < 1  || month > 12  return .{}, false;
    if day   < 1  || day   > 31  return .{}, false;
    if hour  > 23                return .{}, false;
    if min   > 59                return .{}, false;
    if sec   > 59                return .{}, false;

    ct: Calendar_Time;
    ct.year                        = cast(s32) year;
    ct.month_starting_at_0         = cast(s8) (month - 1);
    ct.day_of_month_starting_at_0  = cast(s8) (day - 1);
    ct.hour                        = cast(s8) hour;
    ct.minute                      = cast(s8) min;
    ct.second                      = cast(s8) sec;
    ct.time_zone                   = .UTC;

    return calendar_to_apollo(ct), true;
}

// Format Apollo_Time as "YYYY-MM-DD" using temporary storage.
format_date :: (t: Apollo_Time) -> string {
    ct := to_calendar(t, .UTC);
    return tprint("%-%-%",
        formatInt(ct.year, minimum_digits=4),
        formatInt(ct.month_starting_at_0 + 1, minimum_digits=2),
        formatInt(ct.day_of_month_starting_at_0 + 1, minimum_digits=2));
}

// Convert Apollo_Time to Unix epoch seconds.
to_unix :: (t: Apollo_Time) -> (seconds: s64, ok: bool) {
    diff := t - APOLLO_TIME_FOR_JAN_1_1970;
    seconds, success := to_seconds(diff);
    return seconds, success;
}

// Convert Unix epoch seconds to Apollo_Time.
from_unix :: (seconds: s64) -> Apollo_Time {
    return seconds_to_apollo(seconds) + APOLLO_TIME_FOR_JAN_1_1970;
}

// Return midnight UTC of the same day.
start_of_day :: (t: Apollo_Time) -> Apollo_Time {
    ct := to_calendar(t, .UTC);
    ct.hour        = 0;
    ct.minute      = 0;
    ct.second      = 0;
    ct.millisecond = 0;
    return calendar_to_apollo(ct);
}

// Return the time N hours before now.
hours_ago :: (n: s64) -> Apollo_Time {
    return current_time_consensus() - seconds_to_apollo(n * 3600);
}

// Return the time N days before now.
days_ago :: (n: s64) -> Apollo_Time {
    return current_time_consensus() - seconds_to_apollo(n * 86400);
}

// Floor-align a time to the start of a duration bucket.
// E.g. bucket_start(t, 300) aligns to the nearest 5-minute boundary.
bucket_start :: (t: Apollo_Time, bucket_seconds: s64) -> Apollo_Time {
    unix, ok := to_unix(t);
    if !ok  return t;

    // Floor division (toward negative infinity), not truncation toward zero.
    floored := unix / bucket_seconds - cast(s64)(unix % bucket_seconds != 0 && (unix ^ bucket_seconds) < 0);
    return from_unix(floored * bucket_seconds);
}
