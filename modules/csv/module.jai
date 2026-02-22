
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
