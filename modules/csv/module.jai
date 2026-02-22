
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
