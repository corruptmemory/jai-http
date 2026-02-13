# Jai Language Reference

Condensed reference for writing Jai code. Distilled from `how_to/` in the Jai distribution.

**Jai distribution location:** Expected at `~/jai/jai/`. If not found, ask the user where it is. Standard library modules are at `<jai>/modules/`. The how_to documentation is at `<jai>/how_to/`.

## Declarations and Variables

```jai
name: type = value;     // Full declaration
name: type;             // Default value (zero-initialized)
name := value;          // Type inferred from value
name: type : value;     // Constant (cannot reassign)
name :: value;          // Constant with inferred type (common for procedures, structs)
```

Procedures are typically declared as constants:
```jai
main :: () { }
add :: (a: int, b: int) -> int { return a + b; }
```

## Primitive Types

- **Integers:** `u8`, `u16`, `u32`, `u64`, `s8`, `s16`, `s32`, `s64`
- **Aliases:** `int` = `s64`, `float` = `float32`
- **Floats:** `float32`, `float64`
- **Bool:** `bool` (8 bits)
- **Default literal types:** integer literals → `s64`, float literals → `float32`
- **Hex floats:** `0h7fbf_ffff` (IEEE-754 bit pattern)

Numeric literals auto-convert to smaller types if they fit. Variables do NOT auto-narrow — only widen if the target range fully contains the source range. Use `cast(T) value` for explicit conversion, `cast,no_check(T) value` to skip range checks, `xx value` for auto-cast.

## Pointers

```jai
p: *int;          // Pointer to int
p = *variable;    // Address-of (note: opposite of C's &)
value := p.*;     // Dereference (note: opposite of C's *p)
p.member;         // Auto-dereference for struct member access
```

`*` before a type = "pointer to type". `*` before a value = "address of value". `.*` after a value = dereference. This is the opposite of C.

## Arrays

Three kinds:
```jai
fixed: [8] int;              // Fixed size, elements inline, stack-allocated
view: [] int;                // View: {count: s64, data: *T} — 16 bytes
resizable: [..] int;         // Resizable: {count, data, allocated, allocator} — 40 bytes
```

- Fixed → view: implicit cast
- Resizable → view: implicit cast
- `array_add(*resizable, element)` to append
- All arrays bounds-checked at runtime (can disable)

Array literals:
```jai
numbers := int.[1, 2, 3, 4, 5];
.["a", "b", "c"]              // Type inferred from context
string.[]                      // Empty array (null data pointer)
```

## Strings

A `string` is essentially `[] u8`. Not zero-terminated (but string literals have a hidden zero for C interop). String constants implicitly cast to `*u8`.

```jai
s := "Hello";
s.count;            // 5
s.data;             // *u8
s[0];               // u8 value

// Here strings (verbatim, no escaping):
TEXT :: #string DONE
raw content here, no escapes needed
DONE
```

Key functions: `sprint` (allocates), `tprint` (temporary storage), `print` (stdout), `copy_string`.

## Structs

```jai
Vector3 :: struct {
    x, y, z: float;           // Compound declaration
}

Ice_Cream :: struct {
    flavor := "vanilla";      // Default values
    scoops := 2;
}
```

- Memory layout matches declaration order (no reordering)
- Assignment is memcpy (no constructors/destructors)
- Struct literals: `Vector3.{1, 2, 3}` or `.{x=1}` (type inferred from context)
- `.{}` = all defaults
- `---` in initialization means leave uninitialized: `v: Vector3 = ---;`

### Using

```jai
Entity :: struct {
    using position: Vector3;   // Promotes x, y, z into Entity's namespace
    id: s64;
}

Dog :: struct {
    #as using entity: Entity;  // #as enables implicit cast Dog → Entity
    name: string;
}

dog: Dog;
dog.x = 5;        // Accesses entity.position.x
```

`using` in procedure parameters:
```jai
move :: (using e: *Entity) {
    x += 1;    // Modifies e.position.x
}
```

`using` in statements: `using my_struct;` imports members as local names.

`using,except(name)` and `using,only(name)` for selective import.

## Enums

```jai
Direction :: enum {
    NORTH;       // 0
    SOUTH;       // 1
    EAST;        // 2
    WEST;        // 3
}

// Sized:
Flags :: enum_flags u16 {    // enum_flags: powers of 2, supports bitwise ops
    READ;
    WRITE;
    EXECUTE;
}

// Specified (stable values for serialization):
Op :: enum u32 #specified {
    ADD :: 1;
    SUB :: 2;
}
```

Unary dot: `.NORTH` inferred from context. `using Direction;` imports names into scope.

`#complete` on `if == {}` requires all cases covered.

## Control Flow

### If
```jai
if condition { } else { }
if condition then expr1; else expr2;    // Single-line form
```

### Ifx (expression)
```jai
value := ifx condition then expr1 else expr2;
name := ifx thing then thing.name;       // Omit else = default value
```

### If-case (switch)
```jai
if value == {
    case .NORTH;   action1();
    case .SOUTH;   action2();
    case;          default_action();      // Bare case = default
}
```
- No fall-through by default. Use `#through` for fall-through.
- `#complete` requires all enum cases handled.

### Compile-time conditionals
```jai
#if OS == .LINUX { }          // Compile-time if (no subscope created!)
#ifx OS == .LINUX then "linux" else "other"   // Compile-time expression
```
Both branches must parse but only the active branch is compiled.

## Loops

### While
```jai
while condition { }
while loop_name := condition {      // Named loop
    break loop_name;
    continue loop_name;
}
```

### For
```jai
for 0..9 { print("%\n", it); }              // Range (inclusive both ends)
for value, index: array { }                   // Named iterator
for < array { }                               // Reverse
for * array { it.x = 5; }                     // Pointer iteration (mutation)
for array  if condition  remove it;           // Remove during iteration
```

`it` = current value, `it_index` = current index (defaults). `defer` in loops fires on each iteration exit.

## Procedures

```jai
// Multiple return values:
foo :: () -> int, string { return 42, "hello"; }
a, b := foo();

// Named returns with defaults:
parse :: (s: string) -> ok: bool = false, value: int = 0 { }

// Default arguments:
f :: (x: int, y: int = 10) -> int { return x + y; }

// Named arguments (any order):
f(y = 20, x = 5);

// Varargs:
print_all :: (items: .. string) {
    for items print("%\n", it);
}
print_all(..existing_array);   // Spread operator
```

## Context System

Implicit parameter passed to every procedure. Contains:
- `allocator` / `default_allocator` — memory allocation
- `temporary_storage` — linear bump allocator
- `logger` / `logger_data` — logging
- `assertion_failed` — assert handler
- `stack_trace` — call stack (if enabled)
- `thread_index` — current thread index

```jai
// Read context:
print("%\n", context.thread_index);

// Modify (flows to callees, persists on return):
context.allocator = my_allocator;

// Scoped override (reverts after block):
new_ctx := context;
new_ctx.allocator = pool_allocator;
push_context new_ctx {
    // All alloc() calls use pool_allocator here
}

// Push default context (useful in #c_call):
push_context {
    print("Now I have a context\n");
}

// Extend context globally:
#add_context my_field: int = 42;

// Inline context override at call site:
f(args,, allocator=temp);    // Comma-comma syntax
```

Each thread gets its own Context. `#c_call` procedures don't receive context.

## Temporary Storage

Linear allocator in Context. Ultra-fast (bump pointer). No individual frees.

```jai
s := tprint("file_%", index);       // Allocates from temp storage
array.allocator = temp;              // Resizable array uses temp
reset_temporary_storage();           // Bulk free everything

// Typical server pattern:
while true {
    connection := accept();
    handle_request(connection);
    reset_temporary_storage();       // Per-request reset
}
```

## Memory Management

Four categories by lifetime:
1. **Extremely short-term** → temporary storage
2. **Short-term (per-frame/request)** → temporary storage with periodic reset
3. **Long-term, clear owner** → Pool allocator, bulk free
4. **Long-term, unclear owner** → individual alloc/free (minimize this)

```jai
// Allocator interface:
Allocator_Proc :: #type (mode: Allocator_Mode, size: s64, old_size: s64,
                         old_memory: *void, allocator_data: *void) -> *void;
// Modes: ALLOCATE, RESIZE, FREE, STARTUP, SHUTDOWN,
//        THREAD_START, THREAD_STOP, CREATE_HEAP, DESTROY_HEAP, CAPS
```

Key functions: `alloc(size)`, `free(ptr)`, `New(Type)`, `array_add`, `realloc`.

## Polymorphism (Generics)

### Polymorphic procedures
```jai
square :: (x: $T) -> T { return x * x; }
// $T declares compile-time type variable. Each unique T generates one procedure.

// Type restrictions:
process :: (x: $T/Entity) { }           // T must be Entity or derived
handle :: (x: $T/interface Drawable) { } // Duck typing: T must have Drawable's members
```

### Quick procedures
```jai
count :: x => x.count;
square :: x => x * x;
// Equivalent to (x: $T) -> $R { return x.count; }
```

### Polymorphic structs
```jai
Channel :: struct (T: Type) {
    buffer: [..] T;
    count: int;
}
ch: Channel(int);
ch: Channel(T=float);   // Named parameter
```

### #modify (type transformation)
```jai
proc :: (a: $T) #modify { T = s64; return true; } { }
// Runs at compile time to transform/reject type variables
// Return false to reject: return false, "error message";
```

### Auto-bake
```jai
f :: (dest: *void, $bytes: s64) { }    // $ = must be compile-time constant
g :: (dest: *void, $$bytes: s64) { }   // $$ = bake if constant, dynamic otherwise
```

## Operator Overloading

```jai
operator + :: (a: Vec3, b: Vec3) -> Vec3 { ... }
operator *= :: (a: *Vec3, b: float) { ... }         // Assignment ops take pointer
operator + :: (v: Vec3, s: float) -> Vec3 #symmetric { } // a+b and b+a

// Array subscript:
operator [] :: (c: Container, i: int) -> int { }
operator []= :: (c: *Container, i: int, val: int) { }
operator *[] :: (c: *Container, i: int) -> *int { }  // Preferred: enables all forms
```

## Compile-Time Execution

```jai
VALUE :: #run compute_value();    // Execute at compile time, result is constant

#if CONDITION { }                 // Compile-time conditional

is_constant(expr);                // Check if expression is compile-time known
```

### #insert (code injection)
```jai
#insert "x *= x;";                         // Insert string as code
#insert -> string { return "generated"; }   // Generate and insert
#insert some_code_node;                      // Insert AST node
```

### Metaprogram / Build System
```jai
#run build();   // Entry point for build metaprogram

build :: () {
    w := compiler_create_workspace("target");
    options := get_build_options(w);
    options.output_executable_name = "server";
    set_build_options(options, w);
    add_build_file("main.jai", w);

    // Message interception for code generation:
    compiler_begin_intercept(w);
    while true {
        msg := compiler_wait_for_message();
        if msg.kind == .COMPLETE break;
    }
    compiler_end_intercept(w);

    set_build_options_dc(.{do_output=false});  // Suppress metaprogram output
}
```

### Workspaces
- Isolated compilation targets within one compiler invocation
- Each workspace can have different options, import paths, source files
- Compile in parallel

## Module System

```jai
#import "Basic";                    // Import module
#import "Module"(PARAM=true);       // With module parameters
Math :: #import "Math";             // Named import: Math.sin()
using Math :: #import "Math";       // Using import: sin() directly
#load "other_file.jai";             // Load file into current scope
```

### Module Parameters

**One of Jai's killer features.** Module parameters are compile-time constants that can be configured at import time. Any plausible tunable constant should be exposed as a module parameter — "one never knows" what the consumer will need to adjust.

```jai
// In module.jai — declare parameters with defaults:
#module_parameters (
    CACHE_LINE_SIZE  : s32 = 64,
    READ_BUFFER_SIZE : s32 = 4096,
    MAX_HEADERS      : s32 = 64    // No trailing comma on last param
);

// These are compile-time constants within the module — use them anywhere:
buf: [READ_BUFFER_SIZE] u8;
headers: [MAX_HEADERS] Header;
```

```jai
// At the import site — override any defaults:
#import "http_server"(READ_BUFFER_SIZE = 8192, MAX_HEADERS = 128);

// Or use all defaults:
#import "http_server";
```

**Key points:**
- Values are resolved at compile time — zero runtime overhead
- Works with any compile-time-known type (integers, bools, types, etc.)
- The module code uses them exactly like constants (`::` declarations)
- Unlike C preprocessor macros: scoped, typed, and shown in error messages
- Unlike runtime config: no branches, no indirection, enables static array sizes
- **Design rule:** If a constant could plausibly vary between consumers, make it a module parameter

### Visibility
```jai
#scope_export    // Declarations visible to importers (default in modules)
#scope_file      // Declarations visible only in this file
#scope_module    // Declarations visible within module only
```

## For-Loop Expansions (Custom Iterators)

```jai
for_expansion :: (collection: MyType, body: Code, flags: For_Flags) #expand {
    `it := current_value;        // Backtick exports to caller's scope
    `it_index := current_index;
    #insert body;                // Insert the user's loop body
}

// Named iterator:
for :my_iterator collection { }
```

## Type Variants

```jai
Handle :: #type,distinct u32;       // No implicit cast to/from u32
Filename :: #type,isa string;       // Implicitly casts to string
Pathed :: #type,isa Filename;       // Chain: Pathed → Filename → string
```

## Inline Assembly

```jai
#asm {
    mov result:, 10;
    add count, 17;
}
#asm AVX2 { ... }     // Feature-gated block
```

Register classes: `gpr`, `vec`, `str`, `omr`. Explicit pinning: `t: gpr === a;`. Polymorphic sizes: `popcnt?BITS result, value;`.

## Other Important Directives

- `defer expr;` — Execute on scope exit (including break/continue/return)
- `#caller_location` — Source location of call site (for error reporting)
- `#c_call` — Use C ABI (no context passed)
- `#no_reset` — Preserve compile-time global value into runtime
- `#this` — Reference to containing procedure/struct
- `#expand` — Mark procedure as macro (expands inline at call site)
- `#bake_constants proc(arg=val)` — Specialize a procedure
- `#type_info_none` — Suppress type info for a struct
- `#through` — Fall through in case statement
- `#complete` — Require exhaustive case coverage
- `#string DELIM ... DELIM` — Here-string (no escaping)

## Any Type

```jai
Any :: struct {
    type: *Type_Info;
    value_pointer: *void;
}
```
Stores type + pointer to value. No heap allocation (stores address of original). Used by `print` and variadic functions.

## Type Info (Runtime Reflection)

```jai
info := type_info(MyStruct);     // Returns *Type_Info
info.type;                        // Type_Info_Tag (.STRUCT, .INTEGER, etc.)
info.runtime_size;                // Size in bytes

// Struct members:
si := cast(*Type_Info_Struct) info;
for si.members { ... }           // Iterate struct fields
```

## Unions

### Untagged unions
```jai
Value :: union {
    as_u64:     u64;
    as_float64: float64;
}
// All fields share memory. Size = max field size. Like C unions.
```

### Tagged unions (beta 0.2.023+, bindings 0.2.025+)
A tag field is declared inline after `union`. The tag becomes the first member; all other fields are packed after it respecting alignment.

```jai
Value_Kind :: enum u8 {
    SCALAR :: 0;
    VECTOR :: 1;
    STRING :: 2;
}

Value :: union kind: Value_Kind {
    scalar: float64;
    vector: Vector4;
    _string: string;
}
```

Tag-to-field bindings (0.2.025+) — associate each enum value with a specific field:
```jai
Fruit :: enum u8 {
    APPLE  :: 0;
    BANANA :: 1;
    ORANGE :: 2;
}

Thing :: union fruit: Fruit {
    .APPLE  ,, x: int;
    .BANANA ,, y: float;
    .ORANGE ,, z := "default";
}
```

The bindings are exported via `Type_Info_Struct.tagged_union_bindings` (array of `Type_Info_Tagged_Union_Binding`), enabling compile-time introspection for safe unwrap macros.

Tag type must be integer or `Type`. No built-in unwrap/match semantics yet — use manual `if tag ==` checks. `using` on a tagged union promotes tag and fields into the enclosing struct's namespace.

**Note:** Field addresses may differ within the union due to alignment. If the tag is `u8` and one field is `u8` (offset 1) but another is a pointer (offset 8), they won't overlap at the same address.

### Union inside struct (common pattern)
```jai
Connection :: struct {
    using data: union state: Connection_State {
        .FREE   ,, next_free: *Connection;
        .ACTIVE ,, request:   *HTTP_Request;
    };
    fd: s32;
    // connection.state, connection.next_free, connection.request all accessible directly
}
```

## Struct Layout Control

### `#align N` (field alignment)
Force a struct member to a specific byte alignment:
```jai
Thread_Data :: struct {
    name: string;
    ts: Temporary_Storage;
    ts_data: [4096] u8 #align 64;   // Cache-line aligned
}
```
The field (and all subsequent fields, by default) will be placed at an offset that is a multiple of N. Commonly used with cache-line boundaries (`#align 64`).

### `#no_padding` (packed structs)
Remove all inter-field padding — fields are packed tightly with no alignment gaps:
```jai
WAV_Header :: struct {
    chunk_id:    [4] u8;
    chunk_size:  u32;
    format:      [4] u8;
} #no_padding;
```
Use for binary file formats, network protocols, or C interop where layout must match exactly.

### `#overlay` (field aliasing, replaces deprecated `#place`)
Declare an alternate view of existing fields starting at a given member's offset. Does not add to struct size — it's a zero-cost alias:
```jai
Vector4 :: struct {
    x, y, z, w: float;

    #overlay (x) xy:  Vector2;     // xy.x aliases x, xy.y aliases y
    #overlay (x) xyz: Vector3;     // xyz overlays x,y,z
    #overlay (y) yzw: Vector3;     // yzw overlays y,z,w
    #overlay (x) component: [4] float;  // Array view of all 4
}

Plane3 :: struct {
    a, b, c, d: float;
    #overlay (a) #as vector4: Vector4;  // #as enables implicit cast
    #overlay (a) normal: Vector3;
}
```
`#overlay` members are recognized as aliases by print, serialization, etc. — they won't be double-processed. `#place` is deprecated (warning in 0.2.021, removal imminent).

### Zero-size alignment trick
Force overall struct alignment without adding to its size:
```jai
AMX_State :: struct {
    data: [64] [64] u8;
    _: [0] u8 #align 64;   // Forces struct alignment to 64 bytes
}
```

### Compile-time cache-line padding (polymorphic)

Pad any polymorphic struct's items to a cache-line boundary using compile-time math. Works generically for any `T`:

```jai
Channel :: struct(T: Type) {
    Item :: struct {
        value: T;
        BASE_SIZE    :: size_of(T);
        PADDING_SIZE :: #run Basic.align_forward(BASE_SIZE, CACHE_LINE_SIZE) - BASE_SIZE;
        padding: [PADDING_SIZE] u8;
    }
    items: [] Item;   // Every Item is exactly cache-line sized
}
```

`size_of(T)` and `align_forward` are evaluated at compile time via `#run`. The padding array is computed per-polymorphic-instantiation — `Channel(int)` gets different padding than `Channel(My_Big_Struct)`. Zero runtime cost, works with any `T`, far cleaner than C's `__attribute__((aligned(64)))` or `_Alignas` hacks. Use this pattern anywhere items in contiguous arrays must not share cache lines (ring buffers, connection pools, per-thread slots).

## Testing

Jai has **no built-in test framework**. Tests are just another program.

### Convention
Write test procedures full of `assert()` calls. Build a separate test executable via the metaprogram. If it exits 0, tests pass.

```jai
// tests/test.jai
test_connection_pool :: () {
    pool: Connection_Pool;
    init(*pool, 16);
    defer destroy(*pool);

    c := get_connection(*pool);
    assert(c != null);
    assert(c.state == .ACTIVE);

    free_connection(*pool, c);
    assert(c.state == .FREE);
}

main :: () {
    test_connection_pool();
    print("All tests passed.\n");
}

#import "Basic";
#import "http_server";
```

### Build integration
Use a dedicated workspace in `first.jai` with `Autorun` to compile and auto-run:
```jai
build_tests :: (options: Build_Options) {
    w := compiler_create_workspace("tests");
    // ... set options, add import paths ...
    add_build_file("modules/http_server/tests/test.jai", w);
    // Intercept completion, then:
    Autorun.run_build_result(w);   // Run immediately after compile
}
```
Invoked with: `~/jai/jai/bin/jai-linux first.jai -- test`

### Key primitives
- **`assert(condition, format, args..)`** — from `Basic`. Crashes with message + `#caller_location` on failure.
- **`#assert condition`** — compile-time static assertion (e.g., `#assert size_of(T) == 8`).
- **`@test` note** — informal annotation convention on test procedures. Not processed by the compiler, but a metaprogram could intercept `@test`-annotated procedures via `Message_Typechecked` and auto-generate `#run` calls for them.
- **`#run test_something()`** — run a test at compile time. Catches failures before a binary is produced.

### No built-in facilities for
- Test discovery/runner, pass/fail counts, test isolation, mocking, assertions library. Roll your own as needed.

## Key Differences from C/C++

| Feature | C/C++ | Jai |
|---|---|---|
| Address-of | `&x` | `*x` |
| Dereference | `*p` | `p.*` |
| Generics | Templates (complex) | `$T` (simple, compile-time) |
| Strings | `char*` (null-term) | `string` = `{count, data}` |
| Memory | malloc/free, RAII | Context allocators, temp storage, pools |
| Build | Make/CMake | Compile-time metaprogram in Jai |
| Switch | Fall-through default | No fall-through default, `#through` opt-in |
| Enum scope | Global (C), Scoped (C++) | Scoped, `.VALUE` unary dot |
| Bool cast | Implicit everywhere | Explicit for structs |
| Move semantics | Complex (C++) | Default behavior (memcpy) |
| Closures | Lambdas with capture | No captures; use macros with backtick |
