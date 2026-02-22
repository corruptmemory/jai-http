# CSV Module Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> **REQUIRED:** Before writing ANY Jai code, invoke the `jai-language` skill using the Skill tool.

**Goal:** Build a general-purpose CSV read/write module at `modules/csv/` with compile-time validation via `#code` AST rewriting and `@"csv:..."` struct member notes.

**Architecture:** Single-file module (`modules/csv/module.jai`) using anonymous `#import "Basic"` and `#import "Compiler"`. Column naming controlled by struct member notes. Write path uses `#expand` macro with optional `#code` override blocks for custom formatters. Read path uses header-based column mapping with runtime type_info dispatch. All compile-time machinery (AST walking, `#insert`) runs only during compilation — runtime is just arrays and function pointers.

**Tech Stack:** Jai beta 0.2.026, no external dependencies. Uses Jai standard library: Basic (String_Builder, type_info, formatFloat, print_to_builder), Compiler (compiler_get_nodes, compiler_report, Code AST types).

**Reference:** Design doc at `docs/plans/2026-02-21-csv-module-design.md`. Proven patterns in `experiments/csv_insert_test.jai` and `experiments/csv_macro_test.jai`.

---

### Task 1: Module skeleton and test harness

Create the module file with imports, types, and stub exports. Create the test file with the test struct and empty main. Verify both compile.

**Files:**
- Create: `modules/csv/module.jai`
- Create: `modules/csv/tests/test.jai`
- Modify: `first.jai` (add csv_tests to build_tests)

**Step 1: Create the module file with types and imports**

```jai
// modules/csv/module.jai

#scope_module
#import "Basic";
#import "Compiler";

#scope_export

// Baked struct parameter controls max columns per instance
CSV_Header :: struct ($max_columns: s32 = 64) {
    names:  [max_columns] string;
    count:  s32;
}

CSV_Row :: struct ($max_columns: s32 = 64) {
    fields: [max_columns] string;   // string views into source line
    count:  s32;
}

CSV_Override :: struct {
    field_name:    string;
    write_fn:      *void;       // type-erased fn ptr (runtime dispatch)
    write_fn_type: *Type_Info;  // original fn type (compile-time validation)
}

// Type-erased writer signature for override dispatch
Writer_Fn :: #type (*void, *String_Builder);
```

**Step 2: Create the test file with test struct and empty main**

```jai
// modules/csv/tests/test.jai

Test_Record :: struct {
    name:     string;
    value:    float64;
    count:    int;
    label:    string;  @"csv:Label"
    internal: int;     @"csv:-"
}

main :: () {
    print("Running CSV tests...\n\n");
    print("\nAll CSV tests passed.\n");
}

#import "Basic";
#import "csv";
```

**Step 3: Add csv_tests to first.jai build_tests**

In `first.jai`, add this line inside `build_tests` before `set_build_options_dc`:
```jai
    build_and_run_test("csv_tests", "csv_tests", "modules/csv/tests/test.jai", build_dir);
```

**Step 4: Verify compilation**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: All test suites pass (96 existing + csv_tests prints "All CSV tests passed")

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai first.jai
git commit -m "Add CSV module skeleton with types and test harness"
```

---

### Task 2: Note parsing helpers

Implement `csv_column_name` which reads `@"csv:..."` notes from struct members. This is the foundation that `write_header`, `csv_write_row`, and `read_row` all depend on.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing tests for note parsing**

Add these tests to `test.jai` (before `main`):

```jai
test_csv_column_name_default :: () {
    // Field with no csv note should use field name
    ti := cast(*Type_Info_Struct) type_info(Test_Record);
    name_member := ti.members[0];  // name: string (no note)
    col_name, skip := csv_column_name(name_member);
    assert(col_name == "name", "Expected 'name', got '%'", col_name);
    assert(!skip, "Should not skip");
    print("  PASS: test_csv_column_name_default\n");
}

test_csv_column_name_custom :: () {
    // Field with @"csv:Label" should use custom name
    ti := cast(*Type_Info_Struct) type_info(Test_Record);
    label_member := ti.members[3];  // label: string; @"csv:Label"
    col_name, skip := csv_column_name(label_member);
    assert(col_name == "Label", "Expected 'Label', got '%'", col_name);
    assert(!skip, "Should not skip");
    print("  PASS: test_csv_column_name_custom\n");
}

test_csv_column_name_skip :: () {
    // Field with @"csv:-" should be skipped
    ti := cast(*Type_Info_Struct) type_info(Test_Record);
    internal_member := ti.members[4];  // internal: int; @"csv:-"
    _, skip := csv_column_name(internal_member);
    assert(skip, "Should skip field with @\"csv:-\"");
    print("  PASS: test_csv_column_name_skip\n");
}
```

Add calls in `main`:
```jai
    print("csv_column_name:\n");
    test_csv_column_name_default();
    test_csv_column_name_custom();
    test_csv_column_name_skip();
```

**Step 2: Run tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `csv_column_name` not found (undefined identifier)

**Step 3: Implement csv_column_name**

Add to `modules/csv/module.jai` (in `#scope_export` section):

```jai
// Get the CSV column name for a struct member based on @"csv:..." notes.
// Returns (column_name, should_skip). If skip is true, the field is omitted from CSV.
// Rules:
//   No "csv:" note    → (member.name, false)
//   @"csv:CustomName" → ("CustomName", false)
//   @"csv:-"          → ("", true)
csv_column_name :: (member: Type_Info_Struct_Member) -> (name: string, skip: bool) {
    for note: member.notes {
        if note.count >= 4 {
            prefix := string.{4, note.data};
            if prefix == "csv:" {
                remainder := string.{note.count - 4, note.data + 4};
                if remainder == "-"  return "", true;
                return remainder, false;
            }
        }
    }
    return member.name, false;
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS — all 3 csv_column_name tests pass

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add csv_column_name note parsing helper"
```

---

### Task 3: CSV line splitting (split_line)

Implement RFC 4180 CSV line splitting: handle commas, quoted fields, escaped double-quotes, empty fields.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing tests for split_line**

```jai
test_split_line_simple :: () {
    row := split_line("a,b,c");
    assert(row.count == 3, "Expected 3 fields, got %", row.count);
    assert(row.fields[0] == "a", "Field 0: expected 'a', got '%'", row.fields[0]);
    assert(row.fields[1] == "b", "Field 1: expected 'b', got '%'", row.fields[1]);
    assert(row.fields[2] == "c", "Field 2: expected 'c', got '%'", row.fields[2]);
    print("  PASS: test_split_line_simple\n");
}

test_split_line_quoted :: () {
    row := split_line("\"hello, world\",b");
    assert(row.count == 2, "Expected 2 fields, got %", row.count);
    assert(row.fields[0] == "hello, world", "Field 0: expected 'hello, world', got '%'", row.fields[0]);
    assert(row.fields[1] == "b", "Field 1: expected 'b', got '%'", row.fields[1]);
    print("  PASS: test_split_line_quoted\n");
}

test_split_line_escaped_quotes :: () {
    row := split_line("\"say \"\"hi\"\"\",b");
    assert(row.count == 2, "Expected 2 fields, got %", row.count);
    assert(row.fields[0] == "say \"hi\"", "Field 0: expected 'say \"hi\"', got '%'", row.fields[0]);
    assert(row.fields[1] == "b");
    print("  PASS: test_split_line_escaped_quotes\n");
}

test_split_line_empty_fields :: () {
    row := split_line("a,,c");
    assert(row.count == 3, "Expected 3 fields, got %", row.count);
    assert(row.fields[0] == "a");
    assert(row.fields[1] == "", "Field 1 should be empty, got '%'", row.fields[1]);
    assert(row.fields[2] == "c");
    print("  PASS: test_split_line_empty_fields\n");
}
```

Add calls in `main`:
```jai
    print("\nsplit_line:\n");
    test_split_line_simple();
    test_split_line_quoted();
    test_split_line_escaped_quotes();
    test_split_line_empty_fields();
```

**Step 2: Run tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `split_line` not found

**Step 3: Implement split_line**

Add to `modules/csv/module.jai`:

```jai
// Split a CSV line into fields per RFC 4180.
// Handles: commas, quoted fields, escaped double-quotes (""), empty fields.
// For quoted fields with escaped quotes, the unescaped content is built using
// temporary storage (caller should reset_temporary_storage appropriately).
// Unquoted fields and quoted fields without escaped quotes are zero-copy views
// into the source line.
split_line :: (line: string) -> CSV_Row() {
    row: CSV_Row();
    i := 0;

    while i <= line.count && row.count < row.max_columns {
        if i == line.count {
            // Trailing comma produced an empty final field
            if row.count > 0 && i > 0 && line.data[i-1] == #char "," {
                row.fields[row.count] = "";
                row.count += 1;
            }
            break;
        }

        if line.data[i] == #char "\"" {
            // Quoted field
            i += 1;  // skip opening quote
            start := i;
            has_escapes := false;

            while i < line.count {
                if line.data[i] == #char "\"" {
                    if i + 1 < line.count && line.data[i + 1] == #char "\"" {
                        has_escapes = true;
                        i += 2;  // skip escaped quote
                    } else {
                        break;  // closing quote
                    }
                } else {
                    i += 1;
                }
            }

            if has_escapes {
                // Build unescaped string using temporary storage
                sb: String_Builder;
                sb.allocator = temp;
                j := start;
                while j < i {
                    if line.data[j] == #char "\"" && j + 1 < i && line.data[j + 1] == #char "\"" {
                        append(*sb, "\"");
                        j += 2;
                    } else {
                        append(*sb, string.{1, line.data + j});
                        j += 1;
                    }
                }
                row.fields[row.count] = builder_to_string(*sb,, allocator = temp);
            } else {
                // Zero-copy: view into source line
                row.fields[row.count] = string.{i - start, line.data + start};
            }
            row.count += 1;

            if i < line.count  i += 1;  // skip closing quote
            if i < line.count && line.data[i] == #char ","  i += 1;  // skip comma
        } else {
            // Unquoted field — scan to next comma or end
            start := i;
            while i < line.count && line.data[i] != #char "," {
                i += 1;
            }
            row.fields[row.count] = string.{i - start, line.data + start};
            row.count += 1;
            if i < line.count  i += 1;  // skip comma
        }
    }

    return row;
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS — all 4 split_line tests pass

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add split_line with RFC 4180 CSV parsing"
```

---

### Task 4: parse_header

Wrap `split_line` to parse a header line into a `CSV_Header`.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing test for parse_header**

```jai
test_parse_header :: () {
    header := parse_header("name,value,count,Label");
    assert(header.count == 4, "Expected 4 columns, got %", header.count);
    assert(header.names[0] == "name", "Col 0: expected 'name', got '%'", header.names[0]);
    assert(header.names[1] == "value");
    assert(header.names[2] == "count");
    assert(header.names[3] == "Label", "Col 3: expected 'Label', got '%'", header.names[3]);
    print("  PASS: test_parse_header\n");
}
```

Add to `main`:
```jai
    print("\nparse_header:\n");
    test_parse_header();
```

**Step 2: Run tests to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `parse_header` not found

**Step 3: Implement parse_header**

```jai
// Parse a CSV header line into a CSV_Header.
// Column names are string views into the source line (zero-copy for unquoted headers).
parse_header :: (line: string) -> CSV_Header() {
    row := split_line(line);
    header: CSV_Header();
    header.count = row.count;
    for i: 0..row.count-1 {
        header.names[i] = row.fields[i];
    }
    return header;
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add parse_header wrapping split_line"
```

---

### Task 5: write_header

Write a CSV header row from a struct type's field names, respecting `@"csv:..."` notes.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing test for write_header**

```jai
test_write_header :: () {
    builder: String_Builder;
    write_header(*builder, Test_Record);
    result := builder_to_string(*builder);
    assert(result == "name,value,count,Label", "Expected 'name,value,count,Label', got '%'", result);
    print("  PASS: test_write_header\n");
}
```

Note: `internal` (with `@"csv:-"`) should be omitted. `label` (with `@"csv:Label"`) should appear as "Label".

Add to `main`:
```jai
    print("\nwrite_header:\n");
    test_write_header();
```

**Step 2: Run tests to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `write_header` not found

**Step 3: Implement write_header**

```jai
// Write a CSV header row for struct type T.
// Uses csv_column_name to determine column names from @"csv:..." notes.
// Fields with @"csv:-" are omitted.
write_header :: (builder: *String_Builder, $T: Type) {
    ti := cast(*Type_Info_Struct) type_info(T);
    first := true;
    for member: ti.members {
        col_name, skip := csv_column_name(member);
        if skip  continue;
        if !first  append(builder, ",");
        first = false;
        append(builder, col_name);
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add write_header with note-aware column names"
```

---

### Task 6: write_default_field and csv_write_row (no overrides)

Implement default field serialization (type_info dispatch for string, float, int, bool) and the `csv_write_row` macro without override support first. The override machinery comes in Task 7.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing tests**

```jai
test_write_row_default :: () {
    record := Test_Record.{name = "sensor", value = 72.5, count = 10, label = "outdoor", internal = 999};
    builder: String_Builder;
    csv_write_row(*builder, *record);
    result := builder_to_string(*builder);
    // internal (csv:-) should be omitted
    // Expect: "sensor",72.5,10,"outdoor"
    assert(result == "\"sensor\",72.5,10,\"outdoor\"",
        "Expected '\"sensor\",72.5,10,\"outdoor\"', got '%'", result);
    print("  PASS: test_write_row_default\n");
}

test_write_row_skip_field :: () {
    // Verify the @"csv:-" field is truly omitted (not just empty)
    record := Test_Record.{name = "a", value = 1.0, count = 2, label = "b", internal = 42};
    builder: String_Builder;
    csv_write_row(*builder, *record);
    result := builder_to_string(*builder);
    // Should have exactly 3 commas (4 fields), not 4 commas (5 fields)
    comma_count := 0;
    for i: 0..result.count-1 {
        if result.data[i] == #char ","  comma_count += 1;
    }
    assert(comma_count == 3, "Expected 3 commas (4 fields), got % commas", comma_count);
    print("  PASS: test_write_row_skip_field\n");
}

test_write_row_custom_column_name :: () {
    // The column NAME doesn't affect write_row output (names only matter for headers).
    // But the field with @"csv:Label" should still be WRITTEN (just with custom header name).
    record := Test_Record.{name = "x", value = 0.0, count = 0, label = "my-label", internal = 0};
    builder: String_Builder;
    csv_write_row(*builder, *record);
    result := builder_to_string(*builder);
    // label field should appear in output
    assert(result == "\"x\",0,0,\"my-label\"",
        "Expected '\"x\",0,0,\"my-label\"', got '%'", result);
    print("  PASS: test_write_row_custom_column_name\n");
}
```

Add to `main`:
```jai
    print("\ncsv_write_row:\n");
    test_write_row_default();
    test_write_row_skip_field();
    test_write_row_custom_column_name();
```

**Step 2: Run tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `csv_write_row` not found

**Step 3: Implement write_default_field and csv_write_row**

Add to `modules/csv/module.jai`. Note: `write_default_field` is `#scope_module` (internal), `csv_write_row` is exported.

```jai
#scope_module

// Write a CSV-formatted field value using type_info dispatch.
// Strings are always double-quoted with RFC 4180 escaping.
// Floats use default formatting. Integers use decimal. Bools use true/false.
write_default_field :: (field_ptr: *void, field_type: *Type_Info, builder: *String_Builder) {
    if field_type.type == {
        case .STRING;
            value := (cast(*string) field_ptr).*;
            // RFC 4180: quote strings, escape internal quotes
            append(builder, "\"");
            for i: 0..value.count-1 {
                if value.data[i] == #char "\"" {
                    append(builder, "\"\"");
                } else {
                    append(builder, string.{1, value.data + i});
                }
            }
            append(builder, "\"");
        case .FLOAT;
            if field_type.runtime_size == 8 {
                value := (cast(*float64) field_ptr).*;
                print_to_builder(builder, "%", value);
            } else {
                value := (cast(*float32) field_ptr).*;
                print_to_builder(builder, "%", value);
            }
        case .INTEGER;
            ti_int := cast(*Type_Info_Integer) field_type;
            if ti_int.signed {
                if field_type.runtime_size == {
                    case 8; print_to_builder(builder, "%", (cast(*s64) field_ptr).*);
                    case 4; print_to_builder(builder, "%", (cast(*s32) field_ptr).*);
                    case 2; print_to_builder(builder, "%", (cast(*s16) field_ptr).*);
                    case 1; print_to_builder(builder, "%", (cast(*s8)  field_ptr).*);
                }
            } else {
                if field_type.runtime_size == {
                    case 8; print_to_builder(builder, "%", (cast(*u64) field_ptr).*);
                    case 4; print_to_builder(builder, "%", (cast(*u32) field_ptr).*);
                    case 2; print_to_builder(builder, "%", (cast(*u16) field_ptr).*);
                    case 1; print_to_builder(builder, "%", (cast(*u8)  field_ptr).*);
                }
            }
        case .BOOL;
            value := (cast(*bool) field_ptr).*;
            append(builder, ifx value then "true" else "false");
        case;
            append(builder, "");
    }
}

#scope_export
```

Then add `csv_write_row`. This is the `#expand` macro. For now, implement WITHOUT override support — just default field writing with note awareness. Override machinery comes in Task 7.

```jai
// Write one struct instance as a CSV row.
// Respects @"csv:-" (skip) and @"csv:Name" (custom name doesn't affect output, only headers).
// Optional override_code parameter accepts #code .[ make_override("field", fn), ... ] for
// custom field formatters (see make_override). Default: no overrides.
csv_write_row :: (builder: *String_Builder, row: *$T, override_code: Code = #code .[]) #expand {
    // -- Compile-time override processing --
    // generate_overrides_code walks the #code AST, validates field names against type_info(T),
    // and generates make_override_internal() calls with the struct type injected.
    generate_overrides_code :: (code: Code, struct_ti: *Type_Info) -> string {
        si := cast(*Type_Info_Struct) struct_ti;
        struct_name := si.name;
        root, expressions := compiler_get_nodes(code);

        sb: String_Builder;
        append(*sb, "_csv_overrides := CSV_Override.[\n");

        for expressions {
            if it.kind != .PROCEDURE_CALL continue;
            call := cast(*Code_Procedure_Call) it;

            if call.procedure_expression.kind != .IDENT continue;
            proc_ident := cast(*Code_Ident) call.procedure_expression;
            if proc_ident.name != "make_override" continue;

            args := call.arguments_unsorted;
            if args.count != 2 {
                compiler_report("make_override expects exactly 2 arguments: (field_name, write_fn)");
                return "";
            }

            // Arg 0: string literal (field name)
            field_expr := args[0].expression;
            if field_expr.kind != .LITERAL {
                compiler_report("make_override: first argument must be a string literal");
                return "";
            }
            literal := cast(*Code_Literal) field_expr;
            if literal.value_type != .STRING {
                compiler_report("make_override: first argument must be a string literal");
                return "";
            }
            field_name := literal._string;

            // Validate field exists on the struct at compile time
            field_found := false;
            for member: si.members {
                if member.name == field_name {
                    field_found = true;
                    break;
                }
            }
            if !field_found {
                compiler_report(sprint(
                    "CSV override error: field '%' does not exist on struct '%'",
                    field_name, struct_name));
                return "";
            }

            // Arg 1: identifier (function name)
            fn_expr := args[1].expression;
            if fn_expr.kind != .IDENT {
                compiler_report("make_override: second argument must be a function identifier");
                return "";
            }
            fn_ident := cast(*Code_Ident) fn_expr;

            print_to_builder(*sb, "    make_override_internal(%, \"%\", %),\n",
                struct_name, field_name, fn_ident.name);
        }

        append(*sb, "];\n");
        return builder_to_string(*sb);
    }

    // Run AST walker at compile time, inject generated overrides
    _gen :: #run generate_overrides_code(override_code, type_info(T));
    #insert,scope() _gen;

    // -- Runtime row writing --
    ti := cast(*Type_Info_Struct) type_info(T);
    first := true;
    for member: ti.members {
        _, skip := csv_column_name(member);
        if skip  continue;

        if !first  append(builder, ",");
        first = false;

        field_ptr := cast(*void)(cast(*u8) row + member.offset_in_bytes);

        // Check for override
        has_override := false;
        for override: _csv_overrides {
            if member.name == override.field_name {
                writer := cast,force(Writer_Fn) override.write_fn;
                writer(field_ptr, builder);
                has_override = true;
                break;
            }
        }

        if !has_override {
            write_default_field(field_ptr, member.type, builder);
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS — all 3 write_row tests pass

**Troubleshooting:** If `float64` formatting produces unexpected output (e.g., `72.5` vs `72.500000`), check the default `%` format. Jai's `print_to_builder` with `%` for float64 should produce reasonable output. If not, use `formatFloat(value, trailing_width=6, zero_removal=.YES)` — but try without first.

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add write_default_field and csv_write_row with note-aware field skipping"
```

---

### Task 7: Override machinery (compile-time validation)

Add `check_field_exists`, `check_signature`, and `make_override_internal` — the compile-time validation functions that the `#insert`-generated code calls. Test with a custom write function.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing test for write_row with override**

```jai
// Custom formatter for the test
write_value_fixed :: (value: *float64, builder: *String_Builder) {
    print_to_builder(builder, "%", formatFloat(value.*, trailing_width=1, zero_removal=.NO));
}

test_write_row_with_override :: () {
    record := Test_Record.{name = "sensor", value = 72.5, count = 10, label = "outdoor", internal = 999};
    builder: String_Builder;
    csv_write_row(*builder, *record, #code .[
        make_override("value", write_value_fixed),
    ]);
    result := builder_to_string(*builder);
    // value field should use custom formatter: "72.5" → "72.5" (fixed 1 decimal)
    // Other fields use defaults
    assert(result == "\"sensor\",72.5,10,\"outdoor\"",
        "Expected '\"sensor\",72.5,10,\"outdoor\"', got '%'", result);
    print("  PASS: test_write_row_with_override\n");
}
```

Add to `main`:
```jai
    test_write_row_with_override();
```

**Step 2: Run tests to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `make_override_internal` not found (the generated code calls it)

**Step 3: Implement compile-time validators and make_override_internal**

Add to `modules/csv/module.jai` in `#scope_module` section:

```jai
// Compile-time validator: check field exists on struct
check_field_exists :: (info: *Type_Info, field_name: string) -> bool {
    si := cast(*Type_Info_Struct) info;
    for member: si.members {
        if member.name == field_name return true;
    }
    return false;
}

// Compile-time validator: check write function signature matches (*FieldType, *String_Builder)
check_signature :: (info: *Type_Info, field_name: string, fn_type: *Type_Info) -> bool {
    si := cast(*Type_Info_Struct) info;

    field_type_info: *Type_Info;
    for member: si.members {
        if member.name == field_name {
            field_type_info = member.type;
            break;
        }
    }
    if !field_type_info return false;

    if fn_type.type != .PROCEDURE return false;
    proc := cast(*Type_Info_Procedure) fn_type;

    if proc.argument_types.count != 2 return false;

    // Arg 0: must be *FieldType
    if proc.argument_types[0].type != .POINTER return false;
    ptr0 := cast(*Type_Info_Pointer) proc.argument_types[0];
    if ptr0.pointer_to != field_type_info return false;

    // Arg 1: must be *String_Builder
    if proc.argument_types[1].type != .POINTER return false;
    ptr1 := cast(*Type_Info_Pointer) proc.argument_types[1];
    if ptr1.pointer_to.type != .STRUCT return false;
    sb_struct := cast(*Type_Info_Struct) ptr1.pointer_to;
    if sb_struct.name != "String_Builder" return false;

    return true;
}
```

Add to `#scope_export` section:

```jai
// Internal override constructor — called from generated code only.
// All $-baked params give compile-time #assert; return value carries runtime fn ptr.
make_override_internal :: ($S: Type, $name: string, $fn: $F) -> CSV_Override {
    #assert check_field_exists(type_info(S), name)
        "CSV override error: field does not exist on struct";
    #assert check_signature(type_info(S), name, type_info(F))
        "CSV override error: write function signature does not match (*FieldType, *String_Builder)";
    return .{
        field_name    = name,
        write_fn      = cast(*void) fn,
        write_fn_type = type_info(F),
    };
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS — override test passes

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add compile-time override validation with make_override_internal"
```

---

### Task 8: read_row

Map parsed CSV row fields into a struct using header-based column mapping and type_info dispatch.

**Files:**
- Modify: `modules/csv/module.jai`
- Modify: `modules/csv/tests/test.jai`

**Step 1: Write failing tests for read_row**

```jai
// Simple struct for read tests (no notes, to test basic functionality first)
Simple_Record :: struct {
    name:  string;
    value: float64;
    count: int;
}

test_read_row :: () {
    header := parse_header("name,value,count");
    row := split_line("sensor,72.5,10");
    result, ok := read_row(row, header, Simple_Record);
    assert(ok, "read_row should succeed");
    assert(result.name == "sensor", "name: expected 'sensor', got '%'", result.name);
    assert(result.value == 72.5, "value: expected 72.5, got %", result.value);
    assert(result.count == 10, "count: expected 10, got %", result.count);
    print("  PASS: test_read_row\n");
}

test_read_row_column_reorder :: () {
    // Columns in different order than struct fields
    header := parse_header("count,name,value");
    row := split_line("10,sensor,72.5");
    result, ok := read_row(row, header, Simple_Record);
    assert(ok, "read_row should succeed with reordered columns");
    assert(result.name == "sensor", "name: expected 'sensor', got '%'", result.name);
    assert(result.value == 72.5, "value: expected 72.5, got %", result.value);
    assert(result.count == 10, "count: expected 10, got %", result.count);
    print("  PASS: test_read_row_column_reorder\n");
}

test_read_row_missing_column :: () {
    // Header doesn't have 'count' column — should fail gracefully
    header := parse_header("name,value");
    row := split_line("sensor,72.5");
    _, ok := read_row(row, header, Simple_Record);
    assert(!ok, "read_row should fail when required column is missing");
    print("  PASS: test_read_row_missing_column\n");
}
```

Add to `main`:
```jai
    print("\nread_row:\n");
    test_read_row();
    test_read_row_column_reorder();
    test_read_row_missing_column();
```

**Step 2: Run tests to verify they fail**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: FAIL — `read_row` not found

**Step 3: Implement parse_field_value and read_row**

Add to `modules/csv/module.jai` in `#scope_module`:

```jai
// Parse a string value into a field based on its type_info.
// Sets the value at field_ptr. Returns false if parsing fails.
parse_field_value :: (field_str: string, field_type: *Type_Info, field_ptr: *void) -> bool {
    if field_type.type == {
        case .STRING;
            (cast(*string) field_ptr).* = field_str;
            return true;
        case .FLOAT;
            val, success, _ := string_to_float(field_str);
            if !success return false;
            if field_type.runtime_size == 8 {
                (cast(*float64) field_ptr).* = val;
            } else {
                (cast(*float32) field_ptr).* = cast(float32) val;
            }
            return true;
        case .INTEGER;
            val, success, _ := to_integer(field_str);
            if !success return false;
            ti_int := cast(*Type_Info_Integer) field_type;
            if ti_int.signed {
                if field_type.runtime_size == {
                    case 8; (cast(*s64) field_ptr).* = val;
                    case 4; (cast(*s32) field_ptr).* = cast(s32) val;
                    case 2; (cast(*s16) field_ptr).* = cast(s16) val;
                    case 1; (cast(*s8)  field_ptr).* = cast(s8)  val;
                }
            } else {
                uval := cast(u64) val;
                if field_type.runtime_size == {
                    case 8; (cast(*u64) field_ptr).* = uval;
                    case 4; (cast(*u32) field_ptr).* = cast(u32) uval;
                    case 2; (cast(*u16) field_ptr).* = cast(u16) uval;
                    case 1; (cast(*u8)  field_ptr).* = cast(u8)  uval;
                }
            }
            return true;
        case .BOOL;
            if field_str == "true"  { (cast(*bool) field_ptr).* = true;  return true; }
            if field_str == "false" { (cast(*bool) field_ptr).* = false; return true; }
            return false;
        case;
            return false;
    }
}
```

Add to `#scope_export`:

```jai
// Map a parsed CSV row's fields into a struct using header column mapping.
// For each struct member, finds the matching column in the header (by csv_column_name),
// then parses the string value into the field's type.
// Returns (result, ok) — ok is false if any non-skipped field's column is missing from header.
read_row :: (row: CSV_Row, header: CSV_Header, $T: Type) -> (result: T, ok: bool) {
    result: T;
    ti := cast(*Type_Info_Struct) type_info(T);

    for member: ti.members {
        col_name, skip := csv_column_name(member);
        if skip  continue;

        // Find column index in header
        col_index := -1;
        for i: 0..header.count-1 {
            if header.names[i] == col_name {
                col_index = i;
                break;
            }
        }

        if col_index < 0  return .{}, false;  // required column missing
        if col_index >= row.count  return .{}, false;  // row too short

        field_ptr := cast(*void)(cast(*u8) *result + member.offset_in_bytes);
        if !parse_field_value(row.fields[col_index], member.type, field_ptr) {
            return .{}, false;  // parse failure
        }
    }

    return result, true;
}
```

**Step 4: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: PASS — all 3 read_row tests pass

**Troubleshooting:** If `string_to_float` is not found, check Jai's Basic module for the correct function name. It may be `string_to_float64` or require `#import "String"`. Check `~/jai/jai/modules/Basic/` for float parsing functions. Similarly, `to_integer` returns `(s64, bool, string)` — verify the return signature matches. If `to_integer` returns different types, adjust the destructuring.

**Step 5: Commit**

```bash
git add modules/csv/module.jai modules/csv/tests/test.jai
git commit -m "Add read_row with header-based column mapping"
```

---

### Task 9: Final integration and full test run

Run the complete test suite, verify all tests pass (existing 96 + new CSV tests), check for any issues.

**Files:**
- None to modify (unless fixing issues found)

**Step 1: Run full test suite**

Run: `~/jai/jai/bin/jai-linux first.jai - test`
Expected: All test suites pass:
- http_server tests: 62 tests
- datetime tests: 19 tests
- channel tests: 15 tests
- csv tests: 13 tests (3 note parsing + 4 split_line + 1 parse_header + 1 write_header + 3 write_row + 1 override + 3 read_row = 16 total including override)

**Step 2: Verify the test output looks clean**

Check that each test section prints its group header and all PASS lines.

**Step 3: Update the weather station checklist**

In `.claude/weather-station-checklist.md`, check off the CSV items that are now complete:
- [x] CSV writer: format row, handle quoting
- [x] CSV reader: parse rows into field arrays

Leave unchecked (app-level, not module-level):
- [ ] CSV writer: auto-create file with header row
- [ ] Date-partitioned file paths
- [ ] File rotation on date rollover

**Step 4: Commit**

```bash
git add .claude/weather-station-checklist.md
git commit -m "Mark CSV module items complete in weather station checklist"
```

---

## Appendix: Module File Layout Reference

The final `modules/csv/module.jai` should be organized as:

```
#scope_module imports (Basic, Compiler)
#scope_module internal functions:
  - check_field_exists
  - check_signature
  - write_default_field
  - parse_field_value
#scope_export public types:
  - CSV_Header, CSV_Row, CSV_Override, Writer_Fn
#scope_export public functions:
  - csv_column_name
  - parse_header
  - split_line
  - write_header
  - csv_write_row (#expand macro)
  - make_override_internal
  - read_row
```

## Appendix: Key Jai Patterns Used

- **Struct member notes:** `field: Type; @"csv:Name"` — note goes AFTER semicolon
- **Baked struct parameters:** `CSV_Header($max_columns: s32 = 64)` — compile-time per-instance
- **#code AST rewriting:** `compiler_get_nodes` → walk → `#insert,scope()` string
- **Constructor validates, value dispatches:** `$`-baked params for `#assert`, return carries runtime ptr
- **Type_Info dispatch:** `cast(*Type_Info_Struct) type_info(T)` → iterate `.members`
- **Zero-copy strings:** `string.{count, data + offset}` — view into source buffer
- **Anonymous Basic import:** `#import "Basic"` at `#scope_module` for operators + utilities
