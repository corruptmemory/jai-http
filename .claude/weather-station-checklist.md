# Weather Station Port — Feature Checklist

Track incremental progress toward rebuilding the weather-station app in Jai.
Updated across sessions. Check items as they're completed and committed.

## Library Gaps (modules/http_server/ or new modules)

### Static File Serving
- [ ] MIME type lookup from file extension
- [ ] Static file handler (path → embedded bytes + Content-Type)
- [ ] Cache-Control header support
- [ ] Tests for MIME lookup and handler

### JSON Serialization
- [ ] Reflection-based struct → JSON string
- [ ] Support: integers, floats, bools, strings
- [ ] Support: fixed arrays, slices
- [ ] Support: nested structs
- [ ] Float formatting in JSON (no trailing garbage)
- [ ] String escaping (quotes, backslash, control chars)
- [ ] Tests for all supported types

### Time/Date Handling
- [x] Verify Jai stdlib `calendar_to_apollo()` / `to_calendar()` coverage
- [x] Parse RFC3339 string → Apollo_Time (`parse_rfc3339`, handles T and + separators)
- [ ] Format Apollo_Time → RFC3339 string (not yet needed, add when required)
- [x] Format Apollo_Time → `YYYY-MM-DD` (for directory names) (`format_date`)
- [x] Date arithmetic: start of day, N days ago, N hours ago (`start_of_day`, `days_ago`, `hours_ago`)
- [x] Duration bucketing: group timestamps into fixed intervals (`bucket_start`)
- [x] Unix epoch conversions: `to_unix` / `from_unix`
- [x] Tests for parse/format round-trip and arithmetic (19 tests)

### CSV Read/Write
- [x] CSV writer: format row, handle quoting (`csv_write_row` with `write_default_field` type dispatch)
- [x] CSV writer: header row from struct type (`write_header` with note-aware column names)
- [x] CSV reader: parse rows into field arrays (`split_line` with RFC 4180 quoting support)
- [x] CSV reader: map fields to struct via header (`read_row` with `parse_field_value` type dispatch)
- [x] CSV column naming via `@"csv:NAME"` notes, `@"csv:-"` to skip fields
- [x] Compile-time validated write overrides (`make_override` with `#assert`)
- [x] Tests for write/read round-trip (16 tests)
- [ ] Date-partitioned file paths (`data/YYYY-MM-DD/observations.csv`) — app-level concern
- [ ] File rotation on date rollover — app-level concern

### HTML Response Building
- [ ] Verify `tprint` + pool allocator works for HTML string building
- [ ] Layout helper (HTML shell with CSS/JS includes)
- [ ] Fragment helper (for htmx partial responses)

### Float Formatting
- [x] Verify `formatFloat` with fixed decimal places — `formatFloat(value, trailing_width=1, zero_removal=.NO)` works
- [x] No custom formatter needed

## Application Layer (weather-station app)

### Data Model
- [ ] Observation struct (24 fields)
- [ ] AggregatedPoint struct (13 averaged fields)
- [ ] AmbientWeather query parser (query params → Observation)

### Storage
- [ ] Store struct with date-partitioned CSV
- [ ] Append observation (write CSV row)
- [ ] Read day's observations (parse CSV file)
- [ ] Read date range (iterate directories)

### Collector (Actor Pattern)
- [ ] Command tagged union (Record, Latest, Today, Range, Downsampled)
- [ ] Collector thread using Channel(Command)
- [ ] In-memory cache: today's observations + latest
- [ ] Date rollover handling
- [ ] Downsample algorithm (time-bucket averaging)

### HTTP Handlers
- [ ] `GET /` — Home page (full HTML)
- [ ] `GET /data/report` — Receive station data (parse query, record)
- [ ] `GET /data/report/*` — Wildcard fallback for firmware quirks
- [ ] `GET /api/weather/current` — htmx HTML fragment
- [ ] `GET /api/weather/series` — JSON time-series with range/bucket params
- [ ] `GET /ping` — Health check
- [ ] `GET /static/*filepath` — Embedded static files

### Frontend Assets
- [ ] Port CSS (tokens.css, base.css, components.css)
- [ ] Port charts.js (uPlot rendering, range selection)
- [ ] Port app.js
- [ ] Vendor files (htmx, normalize, uplot) — embed at compile time

### Middleware
- [ ] Request logging middleware
- [ ] Panic recovery middleware (or Jai equivalent)

### Configuration
- [ ] Listen address (CLI flag or hardcoded initially)
- [ ] Data directory path
- [ ] TOML config (stretch goal — can hardcode initially)

## Session Log

Record what was accomplished each session for continuity.

| Date | Session | Accomplished |
|------|---------|-------------|
| 2026-02-21 | Initial | Gap analysis complete, checklist created |
| 2026-02-21 | Datetime | `modules/datetime/` — parse_rfc3339, format_date, to_unix/from_unix, start_of_day, hours_ago/days_ago, bucket_start. 19 tests. Extracted `build_and_run_test` helper in first.jai. Float formatting verified. |
| 2026-02-21 | Channel | Fixed 3 bugs in `modules/channel/`: added `close()`, fixed `send()` recheck after wake, fixed `receive()` to return `(T, bool)` and drain buffered items. Fixed latent named-import compilation bug. 15 tests (single-threaded, multi-threaded, close behavior). 96 tests total. |
| 2026-02-21 | CSV | `modules/csv/` — write_header, csv_write_row (with type-erased overrides), split_line (RFC 4180), parse_header, read_row (header-mapped). Note-based column naming (`@"csv:NAME"`, `@"csv:-"`). Compile-time override validation via baked params + `#assert`. 16 tests. 112 tests total. |
