# CSV Module Design

**Date:** 2026-02-21
**Status:** Approved
**Module path:** `modules/csv/module.jai`

## Goal

General-purpose, reusable CSV read/write module for Jai web applications. Header-based column mapping with compile-time validation. Not tied to any specific application — storage organization and file management are app-level concerns.

## Section 1: Module Structure & Types

Single-file module at `modules/csv/module.jai`. No module parameters — flexibility comes from baked struct parameters.

### Types

```jai
// Baked struct parameter controls max columns per instance
CSV_Header :: struct ($max_columns: s32 = 64) {
    names:  [max_columns] string;
    count:  s32;
}

CSV_Override :: struct {
    field_name:    string;
    write_fn:      *void;       // type-erased fn ptr (runtime dispatch)
    write_fn_type: *Type_Info;  // original fn type (compile-time validation)
}

CSV_Row :: struct ($max_columns: s32 = 64) {
    fields: [max_columns] string;   // string views into source line
    count:  s32;
}
```

### Column Naming via Notes

Struct members use `@"csv:..."` notes (placed after the semicolon on the same line):

```jai
Weather_Sample :: struct {
    timestamp:   string;              // column name: "timestamp" (field name)
    temperature: float64;             // column name: "temperature" (field name)
    humidity:    float64; @"csv:RH"   // column name: "RH" (custom)
    internal_id: int;    @"csv:-"     // omitted from CSV entirely
}
```

Rules:
- No note → column name = field name
- `@"csv:NAME"` → column name = NAME
- `@"csv:-"` → field omitted from CSV

## Section 2: Public API

### Write Path

```jai
// Write CSV header row from struct type's column names
// Uses type_info(T) + notes to determine column names
write_header :: (builder: *String_Builder, $T: Type) { ... }

// Write one struct instance as a CSV row
// override_code: optional #code block with make_override() calls
csv_write_row :: (builder: *String_Builder, row: *$T,
    override_code: Code = #code .[]) #expand { ... }

// User-facing override constructor (used inside #code blocks)
// Name resolved at #insert time, not at #code parse time
make_override :: (field_name: string_literal, write_fn: ident)
```

### Read Path

```jai
// Parse a header line into a CSV_Header
parse_header :: (line: string) -> CSV_Header() { ... }

// Split a CSV line into fields (RFC 4180: quoted fields, escaped quotes)
split_line :: (line: string) -> CSV_Row() { ... }

// Map a parsed row's fields into a struct using header column mapping
// Returns (T, bool) — bool is false if required columns missing
read_row :: (row: CSV_Row, header: CSV_Header, $T: Type) -> (T, bool) { ... }
```

### Helpers

```jai
// Get the CSV column name for a struct member (note-aware)
csv_column_name :: (member: Type_Info_Struct_Member) -> (name: string, skip: bool) { ... }

// Check if a field should be skipped (@"csv:-")
csv_field_skipped :: (member: Type_Info_Struct_Member) -> bool { ... }
```

## Section 3: Internal Architecture

### Compile-Time Flow (write_row with overrides)

1. User calls `csv_write_row(*builder, *row, #code .[ make_override("field", fn) ])`
2. `#expand` macro runs `generate_overrides_code` at compile time via `#run`
3. `compiler_get_nodes(override_code)` walks the flat AST expression list
4. For each `make_override` call: extract field name string literal + fn identifier
5. Validate field exists on `type_info(T)` — `compiler_report` on failure
6. Generate string: `_csv_overrides := CSV_Override.[ make_override_internal(StructType, "field", fn), ... ];`
7. `#insert,scope()` injects the generated code into the macro's scope
8. `make_override_internal` polymorphs with `$S`, `$name`, `$fn: $F` — `#assert` validates signature

### Runtime Flow (write_row)

1. Iterate `type_info(T).members`
2. For each member: check notes for `@"csv:-"` (skip) or `@"csv:NAME"` (custom name)
3. Check `_csv_overrides` array for matching field name
4. If override found: call type-erased `write_fn` via `cast,force(Writer_Fn)`
5. If no override: call `write_default_field` with type_info dispatch (string, float, int, bool)

### Runtime Flow (read_row)

1. For each member in `type_info(T)`: get CSV column name (note-aware)
2. Find column index in `CSV_Header.names` by string match
3. Parse string field into member's type using type_info dispatch
4. Set field value via pointer arithmetic (`cast(*u8) row + member.offset_in_bytes`)

### Note Parsing

```jai
// Scan member.notes for "csv:..." prefix
csv_column_name :: (member: Type_Info_Struct_Member) -> (name: string, skip: bool) {
    for note: member.notes {
        if note.count > 4 && note[0..4] == "csv:" {
            remainder := note;
            advance(*remainder, 4);
            if remainder == "-" return "", true;   // skip
            return remainder, false;                // custom name
        }
    }
    return member.name, false;  // default: field name
}
```

## Section 4: Error Handling

### Compile-Time (hard errors)

- Field name in `make_override` doesn't exist on struct → `compiler_report` during AST walk
- Write function signature mismatch → `#assert` in `make_override_internal` polymorph
- Both produce clear error messages with field name and struct name

### Runtime (soft errors)

- `read_row` returns `(T, bool)` — `false` if required columns not found in header
- `split_line` handles malformed CSV gracefully (unclosed quotes → rest of line is one field)
- No panics, no assertions at runtime — callers check the bool

## Section 5: Testing Strategy

Test file: `modules/csv/tests/test.jai`
Test struct:

```jai
Test_Record :: struct {
    name:     string;
    value:    float64;
    count:    int;
    label:    string;  @"csv:Label"
    internal: int;     @"csv:-"
}
```

### Test Cases (13)

1. **write_header** — produces `name,value,count,Label` (no `internal`)
2. **write_row default** — all fields use default serialization
3. **write_row with override** — custom formatter for one field
4. **write_row skip field** — `@"csv:-"` field omitted
5. **write_row custom column name** — `@"csv:Label"` field writes correctly
6. **split_line simple** — `a,b,c` → 3 fields
7. **split_line quoted** — `"hello, world",b` → 2 fields, comma inside quotes
8. **split_line escaped quotes** — `"say ""hi""",b` → field contains `say "hi"`
9. **split_line empty fields** — `a,,c` → 3 fields, middle is empty
10. **parse_header** — line → CSV_Header with correct names and count
11. **read_row** — header + data line → populated struct
12. **read_row column reorder** — columns in different order than struct fields
13. **read_row missing column** — returns `(T, false)`

Integration into build system: add `build_and_run_test("csv", "csv_tests", "modules/csv/tests/test.jai")` in `first.jai`.
