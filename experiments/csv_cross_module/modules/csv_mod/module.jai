
#scope_module
#import "Basic";
#import "Compiler";

#scope_export

CSV_Override :: struct {
    field_name:    string;
    write_fn:      *void;
    write_fn_type: *Type_Info;
}

Writer_Fn :: #type (*void, *String_Builder);

// Internal override constructor — all $-baked, so #assert fires at compile time.
// Exported so the caller's scope can see it when #insert resolves identifiers.
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

csv_write_row :: (builder: *String_Builder, row: *$T, override_code: Code = #code .[]) #expand {

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

            // Validate field exists
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

            print_to_builder(*sb, "    make_override_internal(`%, \"%\", `%),\n",
                struct_name, field_name, fn_ident.name);
        }

        append(*sb, "];\n");
        return builder_to_string(*sb);
    }

    _gen :: #run generate_overrides_code(override_code, type_info(T));
    #insert,scope() _gen;  // ,scope() — resolve in caller's scope for #expand macro

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

#scope_module

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

    if proc.argument_types[0].type != .POINTER return false;
    ptr0 := cast(*Type_Info_Pointer) proc.argument_types[0];
    if ptr0.pointer_to != field_type_info return false;

    if proc.argument_types[1].type != .POINTER return false;
    ptr1 := cast(*Type_Info_Pointer) proc.argument_types[1];
    if ptr1.pointer_to.type != .STRUCT return false;
    sb_struct := cast(*Type_Info_Struct) ptr1.pointer_to;
    if sb_struct.name != "String_Builder" return false;

    return true;
}

write_default_field :: (field_ptr: *void, field_type: *Type_Info, builder: *String_Builder) {
    if field_type.type == {
        case .STRING;
            value := (cast(*string) field_ptr).*;
            append(builder, "\"");
            append(builder, value);
            append(builder, "\"");
        case .FLOAT;
            if field_type.runtime_size == 8 {
                print_to_builder(builder, "%", (cast(*float64) field_ptr).*);
            } else {
                print_to_builder(builder, "%", (cast(*float32) field_ptr).*);
            }
        case .INTEGER;
            ti_int := cast(*Type_Info_Integer) field_type;
            if ti_int.signed {
                if field_type.runtime_size == {
                    case 8; print_to_builder(builder, "%", (cast(*s64) field_ptr).*);
                    case 4; print_to_builder(builder, "%", (cast(*s32) field_ptr).*);
                }
            } else {
                if field_type.runtime_size == {
                    case 8; print_to_builder(builder, "%", (cast(*u64) field_ptr).*);
                    case 4; print_to_builder(builder, "%", (cast(*u32) field_ptr).*);
                }
            }
        case;
            append(builder, "???");
    }
}
