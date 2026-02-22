
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

main :: () {
    print("Running CSV tests...\n\n");

    print("csv_column_name:\n");
    test_csv_column_name_default();
    test_csv_column_name_custom();
    test_csv_column_name_skip();

    print("\nAll CSV tests passed.\n");
}

#import "Basic";
#import "csv";
