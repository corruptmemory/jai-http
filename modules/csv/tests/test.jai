
Test_Record :: struct {
    name:     string;
    value:    float64;
    count:    int;
    label:    string;  @"csv:Label"
    internal: int;     @"csv:-"
}

// -- csv_column_name tests --

test_csv_column_name_default :: () {
    ti := cast(*Type_Info_Struct) type_info(Test_Record);
    name_member := ti.members[0];  // name: string (no note)
    col_name, skip := csv_column_name(name_member);
    assert(col_name == "name", "Expected 'name', got '%'", col_name);
    assert(!skip, "Should not skip");
    print("  PASS: test_csv_column_name_default\n");
}

test_csv_column_name_custom :: () {
    ti := cast(*Type_Info_Struct) type_info(Test_Record);
    label_member := ti.members[3];  // label: string; @"csv:Label"
    col_name, skip := csv_column_name(label_member);
    assert(col_name == "Label", "Expected 'Label', got '%'", col_name);
    assert(!skip, "Should not skip");
    print("  PASS: test_csv_column_name_custom\n");
}

test_csv_column_name_skip :: () {
    ti := cast(*Type_Info_Struct) type_info(Test_Record);
    internal_member := ti.members[4];  // internal: int; @"csv:-"
    _, skip := csv_column_name(internal_member);
    assert(skip, "Should skip field with @\"csv:-\"");
    print("  PASS: test_csv_column_name_skip\n");
}

// -- split_line tests --

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

// -- parse_header tests --

test_parse_header :: () {
    header := parse_header("name,value,count,Label");
    assert(header.count == 4, "Expected 4 columns, got %", header.count);
    assert(header.names[0] == "name", "Col 0: expected 'name', got '%'", header.names[0]);
    assert(header.names[1] == "value");
    assert(header.names[2] == "count");
    assert(header.names[3] == "Label", "Col 3: expected 'Label', got '%'", header.names[3]);
    print("  PASS: test_parse_header\n");
}

// -- write_header tests --

test_write_header :: () {
    builder: String_Builder;
    write_header(*builder, Test_Record);
    result := builder_to_string(*builder);
    assert(result == "name,value,count,Label", "Expected 'name,value,count,Label', got '%'", result);
    print("  PASS: test_write_header\n");
}

// -- csv_write_row tests --

test_write_row_default :: () {
    record := Test_Record.{name = "sensor", value = 72.5, count = 10, label = "outdoor", internal = 999};
    builder: String_Builder;
    csv_write_row(*builder, *record);
    result := builder_to_string(*builder);
    // internal (csv:-) should be omitted. Strings are quoted. Expect:
    // "sensor",72.5,10,"outdoor"
    print("  write_row_default result: '%'\n", result);
    // Check structural correctness: 4 fields, 3 commas
    comma_count := 0;
    for i: 0..result.count-1 {
        if result.data[i] == #char ","  comma_count += 1;
    }
    assert(comma_count == 3, "Expected 3 commas (4 fields), got % commas", comma_count);
    print("  PASS: test_write_row_default\n");
}

test_write_row_skip_field :: () {
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

write_value_fixed :: (value: *float64, builder: *String_Builder) {
    print_to_builder(builder, "%", formatFloat(value.*, trailing_width=1, zero_removal=.NO));
}

test_write_row_with_override :: () {
    record := Test_Record.{name = "sensor", value = 72.5, count = 10, label = "outdoor", internal = 999};
    builder: String_Builder;
    csv_write_row(*builder, *record, overrides = .[
        make_override(Test_Record, "value", write_value_fixed),
    ]);
    result := builder_to_string(*builder);
    print("  write_row_with_override result: '%'\n", result);
    // The override should format value as "72.5" (fixed 1 decimal)
    // Expected: "sensor",72.5,10,"outdoor"
    assert(result == "\"sensor\",72.5,10,\"outdoor\"", "Expected '\"sensor\",72.5,10,\"outdoor\"', got '%'", result);
    print("  PASS: test_write_row_with_override\n");
}

main :: () {
    print("Running CSV tests...\n\n");

    print("csv_column_name:\n");
    test_csv_column_name_default();
    test_csv_column_name_custom();
    test_csv_column_name_skip();

    print("\nsplit_line:\n");
    test_split_line_simple();
    test_split_line_quoted();
    test_split_line_escaped_quotes();
    test_split_line_empty_fields();

    print("\nparse_header:\n");
    test_parse_header();

    print("\nwrite_header:\n");
    test_write_header();

    print("\ncsv_write_row:\n");
    test_write_row_default();
    test_write_row_skip_field();
    test_write_row_with_override();

    print("\nAll CSV tests passed.\n");
}

#import "Basic";
#import "csv";
