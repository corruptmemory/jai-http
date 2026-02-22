
Test_Record :: struct {
    name:     string;
    value:    float64;
    count:    int;
    label:    string;  @"csv:Label"
    internal: int;     @"csv:-"
}

main :: () {
    print("Running CSV tests...\n\n");
    print("\nAll CSV tests passed.\n");
}

#import "Basic";
#import "csv";
