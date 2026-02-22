// Experiment: #code AST Rewriting to Eliminate Struct Type Boilerplate
//
// Builds on csv_macro_test.jai. Proves that a Jai #expand macro can:
//   1. Accept #code .[ make_override("field", fn), ... ] as a Code value
//   2. Walk the AST at compile time to extract field names and fn identifiers
//   3. Validate field names against the struct type (inferred from *$T)
//   4. Generate make_override_internal(StructType, ...) calls via string #insert
//   5. Get compile-time signature validation from make_override_internal's #assert
//
// User API — no struct type anywhere:
//   csv_write_row(*builder, *sample, #code .[
//       make_override("temperature", write_temperature),
//   ]);
//
// Compile: ~/jai/jai/bin/jai-linux experiments/csv_insert_test.jai
// Run:     ./experiments/csv_insert_test

#import "Basic";
#import "Compiler";

// ============================================================
// Test Struct
// ============================================================

Weather_Sample :: struct {
    timestamp:   string;
    temperature: float64;
    humidity:    float64;
}

// ============================================================
// Override Descriptor
// ============================================================

CSV_Override :: struct {
    field_name:    string;
    write_fn:      *void;       // type-erased fn ptr (runtime dispatch)
    write_fn_type: *Type_Info;  // original fn type (compile-time validation)
}

// ============================================================
// Compile-Time Validators
// ============================================================

check_field_exists :: (info: *Type_Info, field_name: string) -> bool {
    si := cast(*Type_Info_Struct) info;
    for member: si.members {
        if member.name == field_name return true;
    }
    return false;
}

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

// ============================================================
// Internal Override Constructor
//
// Called from GENERATED code only. All $-baked params give
// compile-time #assert; return value carries runtime fn ptr.
// ============================================================

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

// ============================================================
// The Macro — AST rewriting + string #insert
//
// 1. #run walks the Code AST, finds make_override() calls
// 2. Validates field names against type_info(T) at compile time
// 3. Generates string with make_override_internal(T, ...) calls
// 4. #insert,scope() injects the generated overrides array
// 5. Signature validation fires when make_override_internal polymorphs
// ============================================================

Writer_Fn :: #type (*void, *String_Builder);

csv_write_row :: (builder: *String_Builder, row: *$T, override_code: Code = #code .[]) #expand {

    // Compile-time AST walker: extracts make_override calls from the Code,
    // validates field names, and generates make_override_internal calls
    // with the struct type injected.
    generate_overrides_code :: (code: Code, struct_ti: *Type_Info) -> string {
        si := cast(*Type_Info_Struct) struct_ti;
        struct_name := si.name;

        root, expressions := compiler_get_nodes(code);

        sb: String_Builder;
        append(*sb, "_csv_overrides := CSV_Override.[\n");

        for expressions {
            if it.kind != .PROCEDURE_CALL continue;
            call := cast(*Code_Procedure_Call) it;

            // Only match calls to "make_override"
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
                compiler_report(sprint("CSV override error: field '%' does not exist on struct '%'",
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

    // Run the AST walker at compile time, inject the generated overrides
    _gen :: #run generate_overrides_code(override_code, type_info(T));
    #insert,scope() _gen;

    // _csv_overrides is now a local variable from the #insert above.
    // Do the CSV row writing with runtime override dispatch.
    ti := cast(*Type_Info_Struct) type_info(T);
    first := true;
    for member: ti.members {
        if !first  append(builder, ",");
        first = false;

        field_ptr := cast(*void)(cast(*u8) row + member.offset_in_bytes);

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

// ============================================================
// Default field serializer (type_info-based dispatch)
// ============================================================

write_default_field :: (field_ptr: *void, field_type: *Type_Info, builder: *String_Builder) {
    if field_type.type == {
        case .STRING;
            value := cast(*string) field_ptr;
            append(builder, "\"");
            append(builder, value.*);
            append(builder, "\"");
        case .FLOAT;
            if field_type.runtime_size == 8 {
                value := cast(*float64) field_ptr;
                print_to_builder(builder, "%", value.*);
            } else {
                value := cast(*float32) field_ptr;
                print_to_builder(builder, "%", value.*);
            }
        case .INTEGER;
            ti := cast(*Type_Info_Integer) field_type;
            if ti.signed {
                if field_type.runtime_size == 8 {
                    value := cast(*s64) field_ptr;
                    print_to_builder(builder, "%", value.*);
                } else if field_type.runtime_size == 4 {
                    value := cast(*s32) field_ptr;
                    print_to_builder(builder, "%", value.*);
                }
            } else {
                if field_type.runtime_size == 8 {
                    value := cast(*u64) field_ptr;
                    print_to_builder(builder, "%", value.*);
                }
            }
        case;
            append(builder, "???");
    }
}

// ============================================================
// Custom Write Functions
// ============================================================

write_temperature :: (value: *float64, builder: *String_Builder) {
    print_to_builder(builder, "%", formatFloat(value.*, trailing_width=1, zero_removal=.NO));
}

write_humidity_pct :: (value: *float64, builder: *String_Builder) {
    print_to_builder(builder, "%\%", formatFloat(value.*, trailing_width=0, zero_removal=.NO));
}

// INVALID: takes *string but 'temperature' is float64
write_wrong_type :: (value: *string, builder: *String_Builder) {
    print_to_builder(builder, "%", value.*);
}

// ============================================================
// Main
// ============================================================

main :: () {
    sample := Weather_Sample.{
        timestamp   = "2024-01-15T12:00:00Z",
        temperature = 72.5,
        humidity    = 45.0,
    };

    // --- Test 1: one override (no struct type in user code!) ---
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample, #code .[
            make_override("temperature", write_temperature),
        ]);
        result := builder_to_string(*builder);
        print("One override:     %\n", result);
    }

    // --- Test 2: two overrides ---
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample, #code .[
            make_override("temperature", write_temperature),
            make_override("humidity", write_humidity_pct),
        ]);
        result := builder_to_string(*builder);
        print("Two overrides:    %\n", result);
    }

    // --- Test 3: no overrides (explicit empty) ---
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample, #code .[]);
        result := builder_to_string(*builder);
        print("No overrides:     %\n", result);
    }

    // --- Test 4: no overrides (default parameter) ---
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample);
        result := builder_to_string(*builder);
        print("Default (no arg): %\n", result);
    }

    print("\nExperiment successful — #code AST rewriting + compile-time validation.\n");

    // ================================================================
    // NEGATIVE TESTS — uncomment one at a time to see compile errors
    // ================================================================

    // #bad_field: field doesn't exist — caught during AST walk phase
    // {
    //     builder: String_Builder;
    //     csv_write_row(*builder, *sample, #code .[
    //         make_override("nonexistent", write_temperature),
    //     ]);
    // }

    // #bad_sig: write_wrong_type takes *string, but 'temperature' is float64
    //           — caught during make_override_internal polymorph phase
    // {
    //     builder: String_Builder;
    //     csv_write_row(*builder, *sample, #code .[
    //         make_override("temperature", write_wrong_type),
    //     ]);
    // }
}
