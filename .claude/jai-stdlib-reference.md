# Jai Standard Library Reference

Cheat-sheet for modules in the Jai standard library (`<jai>/modules/`).

## Core / Foundation

### Preload.jai
Loaded before everything else. Defines foundational types.
- **Types:** `Allocator` (proc + data), `Allocator_Mode` (ALLOCATE, RESIZE, FREE, STARTUP, SHUTDOWN, THREAD_START, THREAD_STOP, CREATE_HEAP, DESTROY_HEAP, IS_THIS_YOURS, CAPS), `Context_Base`, `Temporary_Storage`, `Source_Code_Location`, `Stack_Trace_Node`, `Any_Struct`, all `Type_Info_*` variants
- **Intrinsics:** `memcpy`, `memcmp`, `memset`, `compare_and_swap`

### Runtime_Support.jai
Runtime initialization, context management, crash handling.
- **Types:** `Context_Base` (full definition), `Temporary_Storage` (full definition)
- **Functions:** `debug_break()`, `one_time_init()`, default logger, write synchronization

### Basic/
Core utilities. Almost every program imports this.
- **Allocation:** `alloc(size)`, `free(ptr)`, `realloc(ptr, size, old_size)`, `New(T)`, `NewArray(count, T)`
- **Temp storage:** `reset_temporary_storage()`, `get_temporary_storage_mark()`, `set_temporary_storage_mark()`, `auto_release_temp` (macro)
- **Arrays:** `array_add(*arr, item)`, `array_add(*arr)` (returns *T), `array_copy(arr)`, `array_free(arr)`, `array_reset(*arr)`, `array_find(arr, item)`, `array_reserve(*arr, count)`, `array_insert_at(*arr, item, index)`, `array_unordered_remove_by_index(*arr, i)`, `array_ordered_remove_by_index(*arr, i)`, `array_unordered_remove_by_value(*arr, val)`, `array_ordered_remove_by_value(*arr, val)`, `array_add_if_unique(*arr, item)`
- **Printing:** `print(fmt, ..)`, `sprint(fmt, ..)` (allocates), `tprint(fmt, ..)` (temp), `write_string(s)`, `write_strings(..)`, `write_number(n)`, `print_to_builder(*builder, fmt, ..)`
- **Format:** `formatInt(val, base=, minimum_digits=)`, `formatFloat(val, width=, trailing_width=)`, `formatStruct(val, use_newlines_if_long_form=)`
- **String_Builder:** `init_string_builder(*b)`, `append(*b, s)`, `builder_to_string(*b)`, `builder_string_length(*b)`
- **Utility:** `min()`, `max()`, `clamp()`, `swap()`, `assert(condition, msg)`, `log(msg, flags=)`
- **Enum helpers:** `enum_names(T)`, `enum_values_as_enum(T)`, `enum_values_as_s64(T)`, `enum_range(T)`
- **Module params:** `MEMORY_DEBUGGER`, `ENABLE_ASSERT`, `TEMP_ALLOCATOR_POISON_FREED_MEMORY`

## Networking

### Socket/
Cross-platform socket API (POSIX sockets on Linux, Winsock on Windows).
- **Types:** `Socket` (s32 on Unix), `sockaddr_in`, `sockaddr_in6`, `fd_set`
- **Functions:** `socket_init()`, `socket(domain, type, protocol)`, `bind(sock, addr, port)`, `listen(sock, backlog)`, `accept(sock)`, `connect(sock, addr, port)`, `send(sock, data, flags)`, `recv(sock, buffer, flags)`, `close_and_reset(*sock)`, `set_blocking(sock, blocking)`, `set_keepalive(sock, ..)`, `setsockopt(sock, level, optname, val)`
- **Helpers:** `to_string(sockaddr_in)`, `get_last_socket_error()`, `SOCKET_WOULDBLOCK`

### Linux/
Linux-specific APIs. Critical for epoll.
- **Epoll types:** `epoll_event { events: u32, data: epoll_data }`, `epoll_data` (union: ptr, fd, u32, u64)
- **Epoll functions:** `epoll_create(size)`, `epoll_create1(flags)`, `epoll_ctl(epfd, op, fd, *event)`, `epoll_wait(epfd, *events, maxevents, timeout)`, `epoll_pwait(..)`
- **Epoll constants:** `EPOLLIN`, `EPOLLOUT`, `EPOLLERR`, `EPOLLHUP`, `EPOLLRDHUP`, `EPOLLET` (edge-triggered, 1<<31), `EPOLLONESHOT` (1<<30), `EPOLLEXCLUSIVE` (1<<28)
- **Epoll ops:** `EPOLL_CTL_ADD` (1), `EPOLL_CTL_DEL` (2), `EPOLL_CTL_MOD` (3)
- **inotify:** `inotify_init()`, `inotify_add_watch()`, `inotify_rm_watch()`, event masks (IN_CREATE, IN_DELETE, IN_MODIFY, etc.)
- **System:** `sysinfo(*info)` — uptime, loads, totalram, freeram, procs

### POSIX/
POSIX syscall wrappers.
- **Types:** `OS_Error_Code` (distinct s32)
- **Functions:** `errno()`, `set_errno(val)`
- **Macros:** `S_ISDIR()`, `S_ISREG()`, `S_ISLNK()`, `WIFEXITED()`, `WEXITSTATUS()`, `WTERMSIG()`
- **Bindings:** Platform-specific (Linux x64/ARM64, macOS x64/ARM64, Android)

## Concurrency

### Thread/
Threading primitives.
- **Types:** `Thread { index, proc, data, starting_context, .. }`, `Mutex`, `Semaphore`, `Condition_Variable`
- **Thread lifecycle:** `thread_init(t, proc, temp_size)`, `thread_deinit(t)`, `thread_start(t)`, `thread_is_done(t)`
- **Mutex:** `init(*mutex)`, `destroy(*mutex)`, `lock(*mutex)`, `unlock(*mutex)`
- **Semaphore:** `init(*sem)`, `destroy(*sem)`, `wait(*sem)`, `signal(*sem)`
- **Module params:** `LOAD_THREAD_GROUP` (bool), `CACHE_LINE_SIZE` (default 64)

### Atomics.jai
Lock-free atomic operations (x64 assembly).
- **Functions:** `atomic_read(*val)`, `atomic_write(*val, new)`, `atomic_swap(*dest, new)` → old, `atomic_add(*dest, val)` → old, `atomic_sub()`, `atomic_and()`, `atomic_or()`, `atomic_xor()`, `atomic_bit_test_and_set(*dest, bit)`
- **Supported types:** bool, pointers, s8–s64, u8–u64, enums
- **Check:** `IsAtomicScalar(T)` — compile-time validation

### Shared_Memory_Channel/
Zero-copy IPC via circular buffer in shared memory.
- **Types:** `Read_Channel`, `Write_Channel`, `Reserved_Message`, `Read_Message`
- **Functions:** `reader_create_channel()`, `writer_connect()`, `writer_reserve_message()`, `writer_send_packet()`, `reader_get_packet()`

## Memory

### Pool.jai
Bump allocator with block list. Fast allocation, bulk-only free.
- **Type:** `Pool { memblock_size=65536, alignment=8, overwrite_memory, free_memblocks_on_reset, .. }`
- **Functions:** `set_allocators(*pool)`, `get(*pool, nbytes)` → *void, `reset(*pool)`, `release(*pool)`
- **Allocator proc:** `pool_allocator_proc` — use as `context.allocator`

### Flat_Pool.jai
Virtual-memory-based pool. Contiguous address space, auto page commit.
- **Type:** `Flat_Pool { alignment=8, memory_base, current_point, address_limit, .. }`
- **Functions:** `init(*pool, reserve=256MB)`, `get(*pool, nbytes)`, `reset(*pool)`, `fini(*pool)`
- **Allocator proc:** `flat_pool_allocator_proc`
- **Advantage over Pool:** No fragmentation, single contiguous region, no linked lists

### Default_Allocator/
The default heap allocator (wraps OS allocator or rpmalloc).

### Memory/
Bulk memory operations.
- **Functions:** `Memory.copy(dest, src, count)` — uses REP MOVSQ on x64 for large copies

### Overwriting_Allocator/
Debug allocator that overwrites freed memory with a pattern.

### Unmapping_Allocator/
Debug allocator that unmaps pages on free (catches use-after-free via segfault).

## Data Structures

### Hash_Table.jai
Open-addressing hash table with linear probing.
- **Type:** `Table(Key, Value, hash_func, compare_func, LOAD_FACTOR_PERCENT=70)`
- **Functions:** `init(*table, size)`, `deinit(*table)`, `table_add(*table, key, value)`, `table_find(*table, key)` → (*value, found), `table_remove(*table, key)`, `table_reset(*table)`
- **Hash convention:** 0 = empty, 1 = removed, 2+ = valid

### Bucket_Array.jai
Sparse array with stable pointers (elements never move).
- **Type:** `Bucket_Array(T, items_per_bucket)`
- **Functions:** `bucket_array_add(*ba, item)`, `bucket_array_find(*ba, locator)`, `bucket_array_remove(*ba, locator)`
- **Key property:** Pointers to elements remain valid after adds

### Bit_Array.jai
Packed bit storage.
- **Type:** `Bit_Array { slots: []s64, count, allocator }`
- **Functions:** `make_bit_array(count)`, `set_bit(*ba, i)`, `clear_bit(*ba, i)`, `toggle_bit(*ba, i)`, operators `[]` and `[]=`

### Treemap.jai
Red-black tree map.

## Strings

### String/
String manipulation (non-allocating views where possible).
- **Search:** `find_index_from_left(s, needle)`, `find_index_from_right(s, needle)`, `contains(s, sub)`, `begins_with(s, prefix)`, `ends_with(s, suffix)`
- **Compare:** `equal(a, b)`, `equal_nocase(a, b)`, `compare(a, b)`, `compare_nocase(a, b)`
- **Transform:** `to_lower_copy(s)`, `to_upper_copy(s)`, `to_lower_in_place(*s)`, `to_upper_in_place(*s)`, `replace(s, old, new)`
- **Split/Join:** `split(s, sep)`, `join(parts, sep)`, `trim(s)`, `trim_left(s)`, `trim_right(s)`
- **Path ops:** `path_decomp(p)` → (path, basename, ext, basename_with_ext), `path_filename(p)`, `path_extension(p)`, `path_strip_filename(p)`, `is_absolute_path(p)`
- **Parsing:** `scan(format, text)` → []Any (like sscanf), `wildcard_match(s, pattern)`

### Unicode.jai
UTF-8 encoding/decoding.
- **Functions:** `character_utf8_to_utf32()`, `character_utf32_to_utf8()`, `utf8_next_character()`, `utf8_iter` (for-expansion)

## File I/O

### File/
File read/write operations.
- **Functions:** `file_open(name, for_writing=, keep_existing=)`, `file_close(*f)`, `file_write(*f, data)`, `read_entire_file(name)` → string, `write_entire_file(name, data)`
- **Directory:** `make_directory_if_it_does_not_exist(name, recursive=)`
- **Mapping:** `map_entire_file_start(name)`, `map_entire_file_end(*info)` (mmap on supported platforms)

### File_Utilities/
Higher-level file helpers (directory listing, recursive operations).

### File_Async/
Asynchronous file I/O.

### File_Watcher/
OS-level file change notification (inotify on Linux).

## Hashing & Checksums

### Hash.jai
General-purpose hash functions.
- **Functions:** `get_hash(val)` (polymorphic — works on int, string, float, pointer, arrays), `sdbm_hash()`, `djb2_hash()`, `fnv1a_hash()`, `knuth_hash()`

### Crc.jai
CRC64 checksum: `crc64(string) → u64`

### md5.jai
MD5 hash.

### xxHash/
xxHash fast hashing.

### meow_hash/
Meow hash (AES-NI based).

## Sorting

### Sort.jai
Quicksort: `quick_sort(array, comparator)`. Helpers: `compare_floats()`, `compare_strings()`.

### IntroSort.jai
Hybrid sort (quicksort + heapsort + insertion sort): `intro_sort(array, comparator)`. O(n log n) worst case.

### RadixSort.jai
O(n) integer/float sorting by byte distribution.

## Math & SIMD

### Math/
Vector, matrix, quaternion operations.
- **Types:** `Vector2`, `Vector3`, `Vector4`, `Quaternion`, `Complex`, `Matrix2`, `Matrix3`, `Matrix4`
- **Constants:** `PI`, `TAU`, `FLOAT32_MIN/MAX`, `S64_MIN/MAX`, etc.
- **Scalar:** `abs()`, `sqrt()`, `log()`, `exp()`, `floor()`, `ceil()`, `round()`, `frac()`, `saturate()`, `lerp()`
- **Vector:** `dot()`, `cross()`, `normalize()`, `length()`, `distance()`, `reflect()`, `slerp()`, `nlerp()`

### SIMD.jai
Cross-platform SIMD abstraction (prototype).
- **Types:** `SIMD_Array(count, type)`, `Simd_128` (union)
- **Ops:** `set()`, `load()`, `store()`, arithmetic operators, `horizontal_sum()`, `get_mask()`

### Sloppy_Math.jai
Fast approximate math (sin, cos, atan2, etc.).

### Machine_X64.jai
x86-64 CPU feature detection.
- **Functions:** `cpuid(leaf, ecx)`, `get_x86_cpu_features()`
- **Types:** `x86_Feature_Flag` (350+ flags: SSE, AVX, AVX2, AVX512, AES-NI, etc.)

## System & Process

### System.jai
OS queries: `get_username()`, `get_home_directory()`, `get_number_of_processors(query_type)`, `get_path_of_running_executable()`, `read_cpu_counter()` (rdtsc).

### Process/
Spawn and manage child processes.

### Command_Line.jai
Struct-based CLI argument parsing: `parse_arguments(T, flags, help_triggers, args)`. Auto-generates help text from struct fields.

## Compiler / Metaprogramming

### Compiler/
Compiler API for build-time metaprogramming.
- **Workspace:** `compiler_create_workspace()`, `get_build_options()`, `set_build_options()`, `add_build_file()`, `add_build_string()`
- **Interception:** `compiler_begin_intercept()`, `compiler_wait_for_message()`, `compiler_end_intercept()`
- **Messages:** `Message_File`, `Message_Import`, `Message_Phase`, `Message_Typechecked`, `Message_Complete`
- **Code generation:** `compiler_get_nodes(Code)`, `compiler_get_code(*Code_Node)`, `compiler_set_type_info_flags()`

### Code_Visit/
AST visitor utilities for metaprogramming.

### Autorun.jai
Auto-execute built program after compilation: `run_build_result(workspace)`.

### Default_Metaprogram.jai
The default build metaprogram used when none is specified.

### Metaprogram_Plugins.jai
Plugin system for compiler metaprograms.

## Encoding & Serialization

### Base64.jai
`base64_encode()`, `base64_decode()`, `base64url_encode()`, `base64url_decode()`

### Relative_Pointers.jai
Compact pointer types storing offsets instead of absolute addresses. Useful for serialization.
- **Types:** `Relative_Pointer(Storage, Target)`, `Relative_String(Storage)`

### Deep_Copy.jai
Recursive deep copy with cycle detection: `Deep_Copy(value, config)`.

### Reflection.jai
Runtime type manipulation: `set_value_from_string()`, `get_struct_field_info()`, `enum_name_to_value()`.

## Debug & Profiling

### Print_Color.jai
ANSI-colored console output: `print_color(fmt, .., color=)`.

### Print_Vars.jai
Debug macro that prints variable names + values: `print_vars(a, b, c)`.

### Debug/
Debug utilities and symbol loading.

### Iprof/
Instrumented profiling.

### Check/
Runtime checking utilities.

## Graphics & UI (not relevant to server, listed for completeness)

`GL`, `Vulkan`, `d3d11`, `d3d12`, `Metal`, `Simp`, `ImGui`, `GetRect`, `SDL`, `Window_Creation`, `X11`, `Input`, `Gamepad`, `stb_image`, `stb_image_write`, `stb_image_resize`, `stb_vorbis`, `freetype`, `Sound_Player`, `Clipboard`, `Icon.jai`, `Ico_File.jai`, `pl_mpeg`, `MojoShader`, `Srgb.jai`, `Subtitles.jai`

## Platform-Specific

- **Linux/** — epoll, inotify, sysinfo
- **POSIX/** — errno, file mode macros, wait macros
- **Windows.jai** — Win32 API bindings
- **macOS/** — macOS-specific APIs
- **Android/** — Android platform layer
- **iOS/** — iOS platform layer
- **Objective_C/** — Objective-C interop (macOS/iOS)

## Build Support

- **BuildCpp/** — Compile C/C++ code from Jai build scripts
- **Bindings_Generator/** — Auto-generate Jai bindings from C headers
- **generate_c_header.jai** — Generate C headers from Jai code
- **Project_Generator.jai** — Scaffold new projects
- **MacOS_Bundler.jai** — Create macOS .app bundles

## Networking (Extended)

- **Curl/** — libcurl bindings
- **Mail.jai** — Email sending

## Compression

- **lz4/** — LZ4 compression
- **Xar/** — XAR archive format
- **Zip_File_Directory.jai** — ZIP file reading

## Other

- **Wav_File.jai** — WAV audio file reading
- **Text_File_Handler/** — Line-by-line text file processing
- **Keymap/** — Key mapping/binding utilities
- **Jai_Lexer/** — Jai source code lexer
- **PCG.jai** — PCG random number generator
- **Random.jai** — MCG-based PRNG: `random_get()`, `random_seed()`, `random_get_within_range(lo, hi)`
- **Performance_Report.jai** — Performance measurement reporting
- **Remap_Context.jai** — Context remapping utilities
- **Rewrite.jai** — Code rewriting utilities
- **Float16.jai** — Half-precision float conversion
- **Soa.jai** — Struct-of-Arrays layout transformation (compile-time)
