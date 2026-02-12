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
