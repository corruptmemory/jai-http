
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

    print("\nAll CSV tests passed.\n");
}

#import "Basic";
#import "csv";
