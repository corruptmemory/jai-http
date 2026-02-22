
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

#scope_module

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

#scope_export
