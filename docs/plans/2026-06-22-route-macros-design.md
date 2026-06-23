# Route-Registration Macros (compile-time pattern validation)

**Date:** 2026-06-22
**Status:** Approved (design)
**Module:** `modules/http_router/`
**Builds on:** the segment-trie matcher (`docs/plans/2026-06-22-trie-path-matcher-{design,implementation}.md`)

## Goal

Turn the method helpers (`get`/`post`/`put`/`http_delete`/`head`) into `#expand` macros that **parse and validate the route pattern at compile time** — a malformed pattern (e.g. a non-terminal `*wildcard`) becomes a **build error** via `compiler_report`, not a startup `log_error`. Registration itself stays at runtime (merge into the router's trie). Routing behavior, the trie, and the public call sites are unchanged.

This is Phase C of the trie work — the payoff the trie building blocks were shaped for. The mechanism is the established `#expand` + `#insert #run` pattern (cf. `jai-wayland/modules/wayland/marshal.jai`, this repo's `modules/csv/module.jai`).

## What we verified before designing (spikes)

Two throwaway spikes against beta 0.2.029 settled the one real unknown — how a compile-time-computed value reaches runtime:

- A `#run` whose result has a **`[..]` dynamic-array field does NOT bake** — the field comes back `count == 0` (the allocator/allocated baggage isn't serialized).
- A `#run` that **returns a `[]` slice DOES bake** — the compiler relocates the backing and preserves `count`+`data`, **including `string` views into the pattern literal**.

So the parsed pattern is carried as a **slice** (`[] Pattern_Segment`), which bakes and carries its own `.count` — no wrapper struct, no `MAX` cap, no separate count field. **(Worth recording in the `jai-language` skill: `#run` bakes `[]` slices but not `[..]` dynamic-array fields. Non-obvious.)**

## Design

### Data — one struct, parsed result is a slice
```jai
Pattern_Segment :: struct { kind: Seg_Kind; name: string; }  // Seg_Kind already exists (STATIC/PARAM/WILDCARD)
```
`name` is the literal text (STATIC) or the capture name (PARAM/WILDCARD) — a `string` view into the pattern literal. The parsed pattern is a `[] Pattern_Segment`.

### One parser, shared by compile time and runtime
```jai
parse_pattern :: (pattern: string) -> (segs: [] Pattern_Segment, ok: bool, err: string)
```
Extracted from the segment-parsing currently inlined in `build_partial_tree`. Builds the segments into a `[..]` and returns it **as a slice**. No global state. Validates the pattern (today's only rule: a `*wildcard` must be the last segment) → `ok=false` + a human `err` on failure. Runs identically under `#run` (the returned slice bakes as a read-only constant) and at runtime (heap-backed).

### Refactor of the existing builder (keeps its tests green)
```jai
chain_from_segments :: (method: string, segs: [] Pattern_Segment, handler: Route_Handler) -> Trie   // the linear-chain [..] partial trie
build_partial_tree  :: (method: string, pattern: string, handler: Route_Handler) -> (tree: Trie, ok: bool)
                       // = parse_pattern(pattern) then chain_from_segments(...); unchanged signature + behavior
```
`build_partial_tree` keeps its public signature and its 4 existing tests; internally it's now `parse_pattern` + `chain_from_segments`.

### Runtime registration (shared by macros and `route()`)
```jai
register_parsed :: (router: *Router, method: string, segs: [] Pattern_Segment, handler: Route_Handler)
                   // = merge(*router.tree, chain_from_segments(method, segs, handler)); log_error on conflict
```
Builds the small `[..]` chain from the (possibly baked) `segs` — no parsing, just a walk — and calls the **existing tested `merge`**. Duplicate path+method is reported by `merge` as a runtime `log_error`, exactly as today.

### The macros
```jai
get :: (router: *Router, $pattern: string, handler: Route_Handler) #expand {
    SEGS :: #run parse_or_report(pattern);          // compile-time: parse + validate; bake the slice
    register_parsed(router, "GET", SEGS, handler);  // runtime: chain_from_segments -> existing merge
}
// post / put / http_delete / head are identical modulo the method string.
```
`parse_or_report` is a `#run`-only helper:
```jai
parse_or_report :: (pattern: string) -> [] Pattern_Segment {
    segs, ok, err := parse_pattern(pattern);
    if !ok  compiler_report(err);   // compile-time only -> build fails with the human message
    return segs;
}
```
`$pattern` makes the pattern a compile-time constant so `#run` can evaluate it. `register_parsed`/`router`/`handler` are the macro's runtime params, named directly in the expanded body (no backticks needed — they're the macro's own parameters, not caller-scope names).

### Runtime escape hatch — `route()` stays
```jai
route :: (router: *Router, method: string, pattern: string, handler: Route_Handler) {
    segs, ok, err := parse_pattern(pattern);
    if !ok { log_error(err); return; }              // can't compiler_report at runtime
    register_parsed(router, method, segs, handler);
}
```
For computed/non-literal patterns and arbitrary methods. Shares `parse_pattern` with the macro path.

### Error split
- Malformed pattern, macro path → `compiler_report` → **compile error**.
- Malformed pattern, `route()` path → `log_error`, route skipped (startup).
- Duplicate path+method → `log_error` in `merge` (startup), unchanged.

No silent failures.

## Backward compatibility

`get`/`post`/`put`/`http_delete`/`head` change from plain procs `(router, pattern, handler)` to macros `(router, $pattern, handler)`. Macros are called exactly like procs, so **literal call sites are unchanged** — every current example and test passes a string literal, so nothing breaks. A caller with a *computed* pattern must use `route()`. That is the deliberate cost of compile-time validation.

`head` is **new** (the current router has `get`/`post`/`put`/`http_delete`); it's added as a macro alongside the others.

## Files

Macros + `parse_pattern` + `chain_from_segments` + `register_parsed` + `route()` live in `modules/http_router/router.jai`, where registration already lives. Split a `registration.jai` only if `router.jai` grows unwieldy — not preemptively. `module.jai` already imports `Compiler` (used today for the cast-free `route_handler` error), which `parse_or_report` needs for `compiler_report`.

## Out of scope

No generic `handle($method, $pattern, …)` macro and no `options`/`patch`/`connect`/`trace` helpers in the first cut — `route()` covers arbitrary methods, and the extra method macros are one-liners to add later if a real need shows up (YAGNI). No compile-time duplicate-route detection (it needs a compile-time route registry the per-call macro can't see; duplicates stay a runtime `merge` error — deliberately accepted).

## Testing

- **`parse_pattern` — table-driven** (runtime): segment classification (literal / `:name` / `*name`), multi-segment, root `/`, and malformed cases (`*` not last) → `ok=false`. This is the same validator the compile-time path reuses, so testing it at runtime covers the validation logic.
- **Equivalence:** a route registered via a macro and the same route registered via `route()` produce identical dispatch — same handler, same captured params, same 404/405. (Proves the baked-slice path and the runtime path converge on the same trie.)
- **Examples:** `hello_world` (and the others using `get`) switch their registration calls to the macro and still build + serve `GET /` → 200, `GET /missing` → 404.
- **Honest gap — compile-failure isn't unit-testable in a green suite.** The "malformed pattern fails the build" path is verified **once, manually** (insert a bad pattern in a macro call, confirm the build fails with the `compiler_report` message), and documented. The validator itself is covered by the `parse_pattern` tests above. No expect-compile-error harness — not worth the machinery.
- All via `~/jai/jai/bin/jai-linux first.jai - run-tests`. MANDATORY before writing any Jai: invoke the `jai-language` skill.

## Open/explicit decisions (settled)

1. Parsed pattern is a baked **`[] Pattern_Segment` slice** (slices bake; `[..]` fields don't), carrying its own `.count` — no wrapper/`MAX`/count field.
2. Method macros: **`get`/`post`/`put`/`http_delete`/`head`**; `route()` is the runtime/dynamic escape hatch. No generic `handle`, no `options`/`patch` yet.
3. Compile-time error = malformed pattern only (via `compiler_report`); duplicate routes stay a runtime `merge` `log_error`.
