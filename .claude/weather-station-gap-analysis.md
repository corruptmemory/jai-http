# Weather Station Gap Analysis

Analysis of what the Jai HTTP library needs before the Go weather-station app (`~/projects/weather-station/`) can be rebuilt in Jai.

## Source Application Summary

The weather station is a local receiver for an Ambient Weather WS-2902. The station sends sensor data via HTTP GET with ~24 query parameters. The app logs observations to date-partitioned CSV files, keeps today's data in memory, and serves a live dashboard with htmx polling and uPlot charts.

**Routes:**

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | Full HTML dashboard (templ template) |
| `/data/report` | GET | Receives station data via query params |
| `/data/report/*` | GET | Wildcard fallback for firmware quirks |
| `/api/weather/current` | GET | HTML fragment polled by htmx every 10s |
| `/api/weather/series` | GET | JSON time-series for charts (with downsampling) |
| `/ping` | GET | Health check |
| `/static/*` | GET | Embedded CSS, JS, vendor files |

**Middleware:** Request ID, Real IP, Panic Recovery, Request Logging (chi built-ins).

**Data model:** `Observation` struct with 24 fields (temperature, humidity, wind, rain, pressure, solar, UV, battery, timestamps). `AggregatedPoint` struct for downsampled chart data (13 averaged fields + timestamp + count).

**Actor pattern:** Single collector goroutine owns all mutable state. HTTP handlers send typed commands via a buffered channel. Commands: Record, Latest, Today, Range, Downsampled. In-memory cache of today's observations; historical data read from CSV on demand.

**Storage:** Append-only CSV files in `data/YYYY-MM-DD/observations.csv`. File rotation on date rollover. Fixed 24-column header. ~1 observation per minute.

**Frontend:** htmx for 10s polling of current weather HTML fragment. uPlot for 6 time-series charts (temperature, humidity, wind, pressure, solar, rain). Range selector buttons (1h, today, 24h, 7d, 30d) with auto-bucketing. CSS design system with custom properties (tokens).

**Config:** TOML file with server.listen and weather.data_dir. CLI flags override. Reflection-based `gen-config` subcommand.

## What's Already Covered

| Requirement | jai-http Feature | Notes |
|-------------|-----------------|-------|
| Chi-style routing | `router.jai` | GET/POST/PUT/DELETE, params, wildcards |
| Path params (`:name`) | `param()` | Zero-copy into connection buffer |
| Wildcard routes (`*name`) | `match_pattern` | Rest-of-path capture |
| Query param parsing | `query_param()` | URL-decoded, zero-copy fast path |
| Middleware chains | `use()`, `proceed()` | Ordered, short-circuit capable |
| Sub-router mounting | `mount()` | Prefix stripping, middleware merging |
| Per-request pool allocator | Worker.request_pool | Auto-cleanup after dispatch |
| Response helpers | `json()`, `text()`, `html()`, `redirect()` | Set content-type + body |
| Actor pattern | `modules/channel/` | Generic typed blocking queue |
| Form/multipart parsing | `helpers.jai` | For future admin endpoints |

## Gaps

### Gap 1: Static File Serving

**What:** Map wildcard route to compile-time embedded file bytes with correct Content-Type.

**Needed for:** Dashboard CSS/JS/vendor files (`/static/*filepath`).

**Scope:**
- MIME type lookup from file extension (`.css`, `.js`, `.html`, `.png`, `.ico`, etc.)
- Handler function that takes a table of path-to-bytes mappings
- Compile-time embedding via `#run read_entire_file()` at the application level
- Cache-Control headers for vendor files

**Complexity:** Small. The handler itself is ~30 lines. MIME table is a simple string match. The actual embedding is application-level code, not library code.

### Gap 2: JSON Serialization

**What:** Serialize Jai structs to JSON strings for API responses.

**Needed for:** `/api/weather/series` returns `{timestamps: [int64...], series: {temp_f: [float64...], ...}}`.

**Scope:**
- Reflection-based serializer using `type_info` (Jai's compile-time type introspection)
- Types to handle: integers, floats, bools, strings, fixed arrays, struct fields
- Nested structs, arrays of structs
- The Go app uses `map[string][]float64` for series — in Jai this would be a struct with named fields instead
- Optional: `#json_name` note or naming convention for field→key mapping

**Complexity:** Medium. Jai's `Type_Info` system makes reflection straightforward, but JSON escaping, float formatting, and nested type walking need care. Could be a standalone `json` module.

**Note:** Only serialization is needed initially (struct→JSON string). Deserialization (JSON→struct) is not needed for the weather station.

### Gap 3: Time/Date Handling

**What:** Parse, format, and do arithmetic on timestamps.

**Needed for:** Everything — observation timestamps, CSV filenames, RFC3339 parsing, unix epoch for JSON, date partitioning, duration-based bucketing.

**Scope:**
- Parse RFC3339 strings (`2026-02-11T20:56:32Z`) → epoch or calendar struct
- Format epoch → RFC3339 string
- Format epoch → `YYYY-MM-DD` for directory names
- Date arithmetic: "start of today", "24 hours ago", "7 days ago"
- Duration bucketing: group timestamps into 5m/15m/1h buckets
- Jai stdlib has `Apollo_Time`, `get_time()`, `calendar_to_time()`, `time_to_calendar()` in `Basic` — need to verify these cover the needs

**Complexity:** Medium. The primitives exist in Jai's stdlib but RFC3339 parsing/formatting and date arithmetic helpers don't.

### Gap 4: CSV Read/Write

**What:** Append observations to date-partitioned CSV files, read them back for historical queries.

**Needed for:** Data persistence. Each observation is one CSV row with 24 columns.

**Scope:**
- CSV writer: append row, auto-create file with header on first write, proper quoting
- CSV reader: parse rows back into observation struct
- Date-partitioned directory creation (`data/YYYY-MM-DD/`)
- File rotation on date rollover
- Jai's `File` module handles file I/O; just need CSV formatting logic

**Complexity:** Small. Fixed column layout (no arbitrary CSV), so the parser is simple. No need for a general-purpose CSV library — hardcode the observation schema.

### Gap 5: HTML Templating

**What:** Generate HTML responses for the dashboard.

**Needed for:** `/` (full page), `/api/weather/current` (htmx fragment), `/ping`.

**Scope:**
- The Go app uses templ (type-safe compiled templates)
- In Jai, options range from simple `tprint` string building to compile-time template embedding
- Only 3 templates: layout shell, home page, current weather component
- The htmx fragment is the most frequently rendered (~every 10s per client)
- Static portions (layout, chart section) could be compile-time string constants
- Dynamic portions (current readings) need runtime string formatting

**Complexity:** Small for the weather station's needs. A helper that builds HTML strings via `tprint` into the per-request pool allocator is sufficient. No need for a template engine.

### Gap 6: Float Formatting

**What:** Format floats to fixed decimal places (e.g., `39.2` not `39.200001`).

**Needed for:** Temperature, pressure, rain amounts in HTML and CSV.

**Scope:**
- Jai's `formatFloat` in `Basic` supports format specifiers
- Need to verify: does `tprint("%.1", 39.2)` produce `39.2`?
- If not, write a simple fixed-decimal formatter

**Complexity:** Trivial. Likely already works with Jai's format strings.

## Dependency Graph

```
Gap 3 (Time/Date) ← Gap 4 (CSV) ← Application data layer
Gap 3 (Time/Date) ← Gap 2 (JSON) ← Chart API endpoint
Gap 1 (Static Files) ← Dashboard frontend
Gap 5 (HTML Templates) ← Dashboard pages
Gap 6 (Float Formatting) ← Everything that displays numbers
```

Time/date handling is the foundation — CSV and JSON both depend on it. Static file serving and HTML templating are independent of each other. Float formatting is a quick verification.

## Recommended Implementation Order

1. **Float formatting** — 5 minutes, just verify Jai's format strings work
2. **Time/date helpers** — Foundation for everything else
3. **CSV read/write** — Data persistence, enables end-to-end testing
4. **JSON serialization** — Chart API endpoint
5. **Static file serving** — Dashboard frontend assets
6. **HTML templating** — Dashboard pages (can start simple, iterate)

After all gaps are filled, the application-level work is:
- Port the Observation struct and query parser
- Port the collector/actor pattern using Channel module
- Port the Store (CSV + date partitioning)
- Port the downsample algorithm
- Wire up routes and handlers
- Port the frontend assets (CSS/JS unchanged, HTML templates rewritten)
- Add config (TOML parsing or simpler alternative)
