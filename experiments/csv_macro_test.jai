// Experiment: Compile-Time Override Validation via #expand Macro
//
// Proves that a Jai #expand macro can:
//   1. Take a struct pointer and infer its type at compile time
//   2. Accept an overrides array with {field_name, write_fn} tuples
//   3. Verify each field name exists on the struct at compile time
//   4. Verify each write_fn signature matches (*FieldType, *String_Builder)
//   5. Produce a compile-time error if any check fails
//   6. Actually CALL the override functions at runtime via type-erased dispatch
//
// Key insight: validation lives in the constructor (make_override), not
// the macro. $-baked params give compile-time #assert checks while the
// return value carries the runtime function pointer.
//
// Compile: ~/jai/jai/bin/jai-linux experiments/csv_macro_test.jai
// Run:     ./experiments/csv_macro_test

#import "Basic";

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
//
// field_name + write_fn_type are used for compile-time validation
// in make_override. write_fn carries the type-erased function
// pointer for runtime dispatch.
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

    // Find the field's type
    field_type_info: *Type_Info;
    for member: si.members {
        if member.name == field_name {
            field_type_info = member.type;
            break;
        }
    }
    if !field_type_info return false;

    // Must be a procedure type
    if fn_type.type != .PROCEDURE return false;
    proc := cast(*Type_Info_Procedure) fn_type;

    // Must take exactly 2 arguments
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
// Override Constructor
//
// All params are $-baked → #assert fires at compile time.
// Return value is a runtime struct with the actual fn pointer.
// This is the bridge: compile-time validation, runtime dispatch.
// ============================================================

make_override :: ($S: Type, $name: string, $fn: $F) -> CSV_Override {
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
// The Macro — runtime dispatch with type-erased function pointers
// ============================================================

// Type-erased writer signature: takes a raw pointer to the field
// and a String_Builder. The original function interprets the *void
// as its specific pointer type — safe because make_override already
// validated the type correspondence at compile time.
Writer_Fn :: #type (*void, *String_Builder);

csv_write_row :: (builder: *String_Builder, row: *$T, overrides: [] CSV_Override) #expand {
    ti := cast(*Type_Info_Struct) type_info(T);
    first := true;
    for member: ti.members {
        if !first  append(builder, ",");
        first = false;

        field_ptr := cast(*void)(cast(*u8) row + member.offset_in_bytes);

        // Check for override
        has_override := false;
        for override: overrides {
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

// VALID: (*float64, *String_Builder) — matches 'temperature' field
write_temperature :: (value: *float64, builder: *String_Builder) {
    print_to_builder(builder, "%", formatFloat(value.*, trailing_width=1, zero_removal=.NO));
}

// VALID: (*float64, *String_Builder) — matches 'humidity' field
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

    // --- Test 1: one override (temperature gets custom formatting) ---
    {
        overrides := CSV_Override.[
            make_override(Weather_Sample, "temperature", write_temperature),
        ];
        builder: String_Builder;
        csv_write_row(*builder, *sample, overrides);
        result := builder_to_string(*builder);
        print("One override:     %\n", result);
    }

    // --- Test 2: two overrides ---
    {
        overrides := CSV_Override.[
            make_override(Weather_Sample, "temperature", write_temperature),
            make_override(Weather_Sample, "humidity", write_humidity_pct),
        ];
        builder: String_Builder;
        csv_write_row(*builder, *sample, overrides);
        result := builder_to_string(*builder);
        print("Two overrides:    %\n", result);
    }

    // --- Test 3: no overrides — pure default serialization ---
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample, CSV_Override.[]);
        result := builder_to_string(*builder);
        print("No overrides:     %\n", result);
    }

    print("\nExperiment successful — compile-time validation + runtime dispatch.\n");

    // ================================================================
    // NEGATIVE TESTS — uncomment one at a time to see compile errors
    // ================================================================

    // #bad_field: field doesn't exist on Weather_Sample
    // {
    //     overrides := CSV_Override.[
    //         make_override(Weather_Sample, "nonexistent", write_temperature),
    //     ];
    // }

    // #bad_sig: write_wrong_type takes *string, but 'temperature' is float64
    // {
    //     overrides := CSV_Override.[
    //         make_override(Weather_Sample, "temperature", write_wrong_type),
    //     ];
    // }
}
