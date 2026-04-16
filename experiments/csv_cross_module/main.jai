// Cross-module experiment: #expand macro with #code + plain #insert
//
// Tests whether plain #insert (without ,scope()) resolves identifiers
// in the caller's scope when the macro lives in a separate module.
//
// Compile: ~/jai/jai/bin/jai-linux experiments/csv_cross_module/main.jai -import_dir experiments/csv_cross_module
// Run:     ./experiments/csv_cross_module/main

#import "Basic";
#import "csv_mod";

// Caller-defined struct (NOT in the module)
Weather_Sample :: struct {
    timestamp:   string;
    temperature: float64;
    humidity:    float64;
}

// Caller-defined write function (NOT in the module)
write_temperature :: (value: *float64, builder: *String_Builder) {
    print_to_builder(builder, "%", formatFloat(value.*, trailing_width=1, zero_removal=.NO));
}

main :: () {
    sample := Weather_Sample.{
        timestamp   = "2024-01-15T12:00:00Z",
        temperature = 72.5,
        humidity    = 45.0,
    };

    // Test 1: one override — caller's type + caller's function
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample, #code .[
            make_override("temperature", write_temperature),
        ]);
        result := builder_to_string(*builder);
        print("One override:     %\n", result);
        assert(result == "\"2024-01-15T12:00:00Z\",72.5,45", "Test 1 failed: '%'", result);
    }

    // Test 2: no overrides (default parameter)
    {
        builder: String_Builder;
        csv_write_row(*builder, *sample);
        result := builder_to_string(*builder);
        print("No overrides:     %\n", result);
    }

    print("\nCross-module experiment successful!\n");
}
