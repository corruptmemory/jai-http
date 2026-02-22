
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
                row.fields[row.count] = string.{i - start, line.data + start};
            }
            row.count += 1;

            if i < line.count  i += 1;  // skip closing quote
            if i < line.count && line.data[i] == #char ","  i += 1;  // skip comma
        } else {
            // Unquoted field
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

parse_header :: (line: string) -> CSV_Header() {
    row := split_line(line);
    header: CSV_Header();
    header.count = row.count;
    for i: 0..row.count-1 {
        header.names[i] = row.fields[i];
    }
    return header;
}

csv_write_row :: (builder: *String_Builder, row: *$T, override_code: Code = #code .[]) #expand {

    // Compile-time AST walker: extracts make_override() calls from the #code,
    // validates field names against type_info(T), and generates
    // make_override_internal() calls with the struct type injected.
    // Caller-scope identifiers (struct name, write functions) are backtick-prefixed
    // so they resolve in the caller's scope across the module boundary.
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

            // Backtick-prefix caller-scope identifiers (struct name, write fn)
            print_to_builder(*sb, "    make_override_internal(`%, \"%\", `%),\n",
                struct_name, field_name, fn_ident.name);
        }

        append(*sb, "];\n");
        return builder_to_string(*sb);
    }

    _gen :: #run generate_overrides_code(override_code, type_info(T));
    #insert,scope() _gen;

    ti := cast(*Type_Info_Struct) type_info(T);
    first := true;
    for member: ti.members {
        _, skip := csv_column_name(member);
        if skip  continue;

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

// Internal override constructor — called from generated code, not directly by users.
// All parameters are baked ($), so #assert fires at compile time.
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

write_default_field :: (field_ptr: *void, field_type: *Type_Info, builder: *String_Builder) {
    if field_type.type == {
        case .STRING;
            value := (cast(*string) field_ptr).*;
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

parse_field_value :: (field_str: string, field_type: *Type_Info, field_ptr: *void) -> bool {
    if field_type.type == {
        case .STRING;
            (cast(*string) field_ptr).* = field_str;
            return true;
        case .FLOAT;
            if field_type.runtime_size == 8 {
                val, success, _ := string_to_float64(field_str);
                if !success return false;
                (cast(*float64) field_ptr).* = val;
            } else {
                val, success, _ := string_to_float(field_str);
                if !success return false;
                (cast(*float32) field_ptr).* = val;
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

#scope_export

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
