# Route-Registration Macros Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `get`/`post`/`put`/`http_delete` into `#expand` macros (and add `head`) that parse + validate the route pattern at compile time — a malformed pattern becomes a build error via `compiler_report` — registering at runtime through the existing trie `merge`.

**Architecture:** Extract the pattern parser out of `build_partial_tree` into `parse_pattern(pattern) -> ([]Pattern_Segment, ok, err)` (slices bake under `#run`; `[..]` fields don't — verified by spike) and `chain_from_segments(method, segs, handler) -> Trie`. The method macros call `register_parsed(router, method, #run parse_or_report(pattern), handler)`: the inline `#run` parses+validates at compile time and bakes the segment slice; `register_parsed` builds the chain at runtime and calls the existing `merge`. `route()` stays as the runtime/dynamic escape hatch.

**Tech Stack:** Jai (beta 0.2.029), `modules/http_router/`. Build/test via the `first.jai` metaprogram.

**Design doc:** `docs/plans/2026-06-22-route-macros-design.md` (read it first).

## Global Constraints

- **MANDATORY before writing/modifying ANY Jai code:** invoke the `jai-language` skill. Applies to every task and any subagent.
- **Build/test** (from `/home/jim/projects/jai-http`): `~/jai/jai/bin/jai-linux first.jai - run-tests`. A suite passes when it prints its final "All … tests passed." line and exits 0.
- **`http_router` imports `Basic` and `Compiler` NAMED** (`Basic ::`/`Compiler ::` in `module.jai`). In module files, prefix every call: `Basic.array_add`, `Basic.log_error`, `Basic.tprint`, `Compiler.compiler_report`. `string_equals` (from `http_server`) needs no prefix. **Test files import `Basic` anonymously** — bare `assert`/`print` there.
- **Macros use an inline `#run`** (`register_parsed(router, "GET", #run parse_or_report(pattern), handler)`), NOT a named `SEGS :: #run …` constant — a named constant in the macro body would collide if the macro is used twice in one scope.
- **Slice, not `[..]`, is the baked carrier.** `parse_pattern` returns `[] Pattern_Segment`; the `#run` of it bakes (read-only constant in the macro path). Never return a `[..]` from a `#run` that must bake.
- **INDEX DISCIPLINE** (carried from the trie): in `chain_from_segments`, appending to `Trie.nodes` may reallocate it — never hold a `*Trie_Node` across an append; use `s32` indices and re-resolve `t.nodes[idx]` after.
- **No silent failures:** malformed pattern → `compiler_report` (macro path, build error) or `Basic.log_error` (runtime path); duplicate routes → `Basic.log_error` in `merge` (unchanged).
- **Compile-time validation requires literal patterns.** The macros take `$pattern: string`; callers with computed patterns use `route()`. All current examples/tests use literals.
- **Match surrounding style** (4-space indent, aligned declarations).
- **Source-only commits** (no `build_*`/`.build`). Check `git status`; stage only the named source files.

---

## File Structure

- **Modify `modules/http_router/trie.jai`:** add `Pattern_Segment` (exported) near the other types; add `parse_pattern` (exported); add `chain_from_segments` + `parse_or_report` in the `#scope_module` region; refactor `build_partial_tree` to `parse_pattern` + `chain_from_segments` (signature + behavior + its 4 tests unchanged).
- **Modify `modules/http_router/router.jai`:** replace the `get`/`post`/`put`/`http_delete` plain procs with `#expand` macros and add a `head` macro (exported); add `register_parsed` (exported, near them). `route()`, `use`, `mount`, `param`, `dispatch`, `serve` untouched.
- **Modify `modules/http_router/tests/test.jai`:** add `parse_pattern` tests (Task 1) and the `head` + macro/`route()` equivalence tests (Task 2); wire into `main`.
- **No example edits expected:** `hello_world`/`app_state` already call `http_router.get(...)` with literal patterns, which now resolve to the macro. Task 3 verifies they build.

---

## Task 1: Extract `parse_pattern` + `chain_from_segments`; refactor `build_partial_tree`

**Files:**
- Modify: `modules/http_router/trie.jai`
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Consumes: `Trie`, `Seg_Kind`, `Route_Handler`, `trie_add_node`, `substr` (existing in trie.jai); `Basic.array_add`, `Basic.log_error`.
- Produces:
  - `Pattern_Segment :: struct { kind: Seg_Kind; name: string; }` (exported)
  - `parse_pattern :: (pattern: string) -> (segs: [] Pattern_Segment, ok: bool, err: string)` (exported)
  - `chain_from_segments :: (method: string, segs: [] Pattern_Segment, handler: Route_Handler) -> Trie` (`#scope_module`)
  - `build_partial_tree` — unchanged signature `(method, pattern, handler) -> (tree: Trie, ok: bool)`, now implemented via the two above.

- [ ] **Step 1: Write the failing tests** in `modules/http_router/tests/test.jai` (add near the other trie tests, before `main`):

```jai
// -- parse_pattern --

test_parse_simple :: () {
    segs, ok, err := parse_pattern("/users/:id");
    assert(ok, "should parse, err='%'", err);
    assert(segs.count == 2, "expected 2 segments, got %", segs.count);
    assert(segs[0].kind == .STATIC && string_equals(segs[0].name, "users"), "seg0 STATIC users");
    assert(segs[1].kind == .PARAM  && string_equals(segs[1].name, "id"),    "seg1 PARAM id");
    print("  PASS: test_parse_simple\n");
}

test_parse_root :: () {
    segs, ok, _ := parse_pattern("/");
    assert(ok, "root parses");
    assert(segs.count == 0, "root has zero segments, got %", segs.count);
    print("  PASS: test_parse_root\n");
}

test_parse_wildcard :: () {
    segs, ok, _ := parse_pattern("/static/*filepath");
    assert(ok);
    assert(segs.count == 2);
    assert(segs[0].kind == .STATIC   && string_equals(segs[0].name, "static"));
    assert(segs[1].kind == .WILDCARD && string_equals(segs[1].name, "filepath"), "seg1 WILDCARD filepath");
    print("  PASS: test_parse_wildcard\n");
}

test_parse_malformed :: () {
    _, ok, err := parse_pattern("/a/*rest/b");
    assert(!ok, "non-terminal wildcard must fail");
    assert(err.count > 0, "should carry an error message");
    print("  PASS: test_parse_malformed\n");
}
```

Add to `main` (a new section):
```jai
    print("\nTrie - parse_pattern:\n");
    test_parse_simple();
    test_parse_root();
    test_parse_wildcard();
    test_parse_malformed();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: FAIL — `parse_pattern` (and `Pattern_Segment`) undefined.

- [ ] **Step 3: Add `Pattern_Segment`** in `trie.jai`, right after the `Seg_Kind` enum:

```jai
// One parsed pattern segment. name = literal text (STATIC) or capture name (PARAM/WILDCARD),
// a string view into the pattern literal.
Pattern_Segment :: struct {
    kind: Seg_Kind;
    name: string;
}
```

- [ ] **Step 4: Add `parse_pattern`** (exported — place just above `build_partial_tree`):

```jai
// Parse a route pattern into its segments. Returns the segments as a SLICE (a #run of this bakes;
// a [..] field would not). ok=false + a human err on a malformed pattern (today: a '*' wildcard
// that isn't the final segment). No logging here — callers decide compiler_report vs log_error.
parse_pattern :: (pattern: string) -> (segs: [] Pattern_Segment, ok: bool, err: string) {
    result: [..] Pattern_Segment;

    rem := pattern;
    if rem.count > 0 && rem[0] == #char "/" { rem.data += 1; rem.count -= 1; }

    saw_wildcard := false;
    if rem.count > 0 {
        i := 0;
        n := rem.count;
        while i <= n {
            j := i;
            while j < n && rem[j] != #char "/"  j += 1;
            seg := substr(rem, i, j - i);

            if saw_wildcard  return result, false, "'*' wildcard must be the last segment";

            if seg.count > 0 && seg[0] == #char ":" {
                Basic.array_add(*result, .{ .PARAM, substr(seg, 1, seg.count - 1) });
            } else if seg.count > 0 && seg[0] == #char "*" {
                Basic.array_add(*result, .{ .WILDCARD, substr(seg, 1, seg.count - 1) });
                saw_wildcard = true;
            } else {
                Basic.array_add(*result, .{ .STATIC, seg });
            }

            if j >= n  break;
            i = j + 1;
        }
    }

    return result, true, "";
}
```

- [ ] **Step 5: Add `chain_from_segments`** in the `#scope_module` region of `trie.jai` (near `trie_add_node`):

```jai
// Build the linear-chain partial trie for one route from its parsed segments + method + handler.
// (The tree-building half of the old build_partial_tree.) INDEX DISCIPLINE: re-resolve t.nodes[cur]
// after each trie_add_node (which may reallocate t.nodes).
chain_from_segments :: (method: string, segs: [] Pattern_Segment, handler: Route_Handler) -> Trie {
    t: Trie;
    trie_add_node(*t, .STATIC, "");   // root at index 0
    cur: s32 = 0;
    keys: [..] string;

    for segs {
        if it.kind == {
          case .STATIC;
            child := trie_add_node(*t, .STATIC, it.name);
            Basic.array_add(*t.nodes[cur].static_children, child);
            cur = child;
          case .PARAM;
            child := trie_add_node(*t, .PARAM, it.name);
            t.nodes[cur].param_child = child;
            Basic.array_add(*keys, it.name);
            cur = child;
          case .WILDCARD;
            child := trie_add_node(*t, .WILDCARD, it.name);
            t.nodes[cur].wildcard_child = child;
            Basic.array_add(*keys, it.name);
            cur = child;
        }
    }

    Basic.array_add(*t.nodes[cur].endpoints, .{ method = method, handler = handler, param_keys = keys });
    return t;
}
```

- [ ] **Step 6: Refactor `build_partial_tree`** — replace its whole body (currently `trie.jai:45-101`) with the composition. The new function:

```jai
// Parse a pattern and build its partial chain trie. ok=false (after logging) on a malformed pattern.
build_partial_tree :: (method: string, pattern: string, handler: Route_Handler) -> (tree: Trie, ok: bool) {
    segs, ok, err := parse_pattern(pattern);
    if !ok {
        Basic.log_error("http_router: % in pattern '%'", err, pattern);
        return .{}, false;
    }
    return chain_from_segments(method, segs, handler), true;
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — the four `parse_pattern` tests pass, AND the existing `build_partial_tree` tests (`test_build_simple_param`, `test_build_root`, `test_build_wildcard`, `test_build_wildcard_not_last`) still pass unchanged (build_partial_tree's signature + behavior are preserved). All six suites green.

- [ ] **Step 8: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'refactor(http_router): extract parse_pattern + chain_from_segments\n\nSplit build_partial_tree into a slice-returning parser (parse_pattern) and a\nchain builder (chain_from_segments); build_partial_tree is now their\ncomposition (signature + tests unchanged). parse_pattern returns a []slice so\na #run of it bakes. Groundwork for the compile-time route macros.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 2: `register_parsed`, `parse_or_report`, and the method macros

**Files:**
- Modify: `modules/http_router/trie.jai` (add `parse_or_report` in `#scope_module`)
- Modify: `modules/http_router/router.jai` (replace `get`/`post`/`put`/`http_delete` procs with macros, add `head`, add `register_parsed`)
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Consumes: `parse_pattern`, `chain_from_segments`, `merge`, `Pattern_Segment` (Task 1); `Router`, `Route_Handler` (existing); `Compiler.compiler_report`, `Basic.tprint`, `Basic.log_error`.
- Produces:
  - `parse_or_report :: (pattern: string) -> [] Pattern_Segment` (`#scope_module`, `#run`-only — calls `compiler_report` on malformed)
  - `register_parsed :: (router: *Router, method: string, segs: [] Pattern_Segment, handler: Route_Handler)` (exported)
  - `get`/`post`/`put`/`http_delete`/`head` — `#expand` macros `(router: *Router, $pattern: string, handler: Route_Handler)`.

- [ ] **Step 1: Write the failing tests** in `modules/http_router/tests/test.jai`:

```jai
// -- Route macros (compile-time pattern parse) --

macro_head_called: bool;
macro_head_handler :: (req: *Request, resp: *Response) {
    macro_head_called = true;
    resp.status_code = 200;
}

test_macro_head :: () {
    router: Router;
    head(*router, "/ping", macro_head_handler);

    req := Request.{ method = "HEAD", path = "/ping" };
    resp: Response;
    macro_head_called = false;
    dispatch(*router, *req, *resp);
    assert(macro_head_called, "HEAD handler should run");
    assert(resp.status_code == 200, "HEAD /ping -> 200, got %", resp.status_code);
    print("  PASS: test_macro_head\n");
}

macro_eq_id: string;
macro_eq_handler :: (req: *Request, resp: *Response) {
    id, _ := param("id");
    macro_eq_id = id;
    resp.status_code = 200;
}

test_macro_route_equivalence :: () {
    // Same route via the get MACRO and via runtime route() must dispatch identically.
    r_macro: Router;
    get(*r_macro, "/users/:id", macro_eq_handler);

    r_runtime: Router;
    route(*r_runtime, "GET", "/users/:id", macro_eq_handler);

    req := Request.{ method = "GET", path = "/users/42" };

    resp1: Response; macro_eq_id = "";
    dispatch(*r_macro, *req, *resp1);
    assert(resp1.status_code == 200 && string_equals(macro_eq_id, "42"), "macro path: 200 + id=42, got % '%'", resp1.status_code, macro_eq_id);

    resp2: Response; macro_eq_id = "";
    dispatch(*r_runtime, *req, *resp2);
    assert(resp2.status_code == 200 && string_equals(macro_eq_id, "42"), "route() path: 200 + id=42, got % '%'", resp2.status_code, macro_eq_id);

    print("  PASS: test_macro_route_equivalence\n");
}
```

Add to `main`:
```jai
    print("\nRoute macros:\n");
    test_macro_head();
    test_macro_route_equivalence();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: FAIL — `head` undefined (the macro doesn't exist yet).

- [ ] **Step 3: Add `parse_or_report`** in the `#scope_module` region of `trie.jai` (near `parse_pattern`/`chain_from_segments`):

```jai
// Compile-time (#run-only) wrapper: parse + validate, and on a malformed pattern emit a build
// error via compiler_report. Returns just the slice (one return value, so a #run can assign it).
parse_or_report :: (pattern: string) -> [] Pattern_Segment {
    segs, ok, err := parse_pattern(pattern);
    if !ok  Compiler.compiler_report(Basic.tprint("http_router: % in pattern '%'", err, pattern));
    return segs;
}
```

- [ ] **Step 4: Add `register_parsed`** in `router.jai` (just above the registration helpers, where `route` lives):

```jai
// Runtime: build the chain from parsed segments and merge it into the router's trie.
// Duplicate path+method is reported by merge (log_error); we add the method context.
register_parsed :: (router: *Router, method: string, segs: [] Pattern_Segment, handler: Route_Handler) {
    if !merge(*router.tree, chain_from_segments(method, segs, handler)) {
        Basic.log_error("http_router: route registration conflict for method '%'", method);
    }
}
```

- [ ] **Step 5: Replace the `get`/`post`/`put`/`http_delete` procs with macros and add `head`.** In `router.jai`, replace the four proc definitions (currently `router.jai:44-58`) with:

```jai
get :: (router: *Router, $pattern: string, handler: Route_Handler) #expand {
    register_parsed(router, "GET", #run parse_or_report(pattern), handler);
}

post :: (router: *Router, $pattern: string, handler: Route_Handler) #expand {
    register_parsed(router, "POST", #run parse_or_report(pattern), handler);
}

put :: (router: *Router, $pattern: string, handler: Route_Handler) #expand {
    register_parsed(router, "PUT", #run parse_or_report(pattern), handler);
}

http_delete :: (router: *Router, $pattern: string, handler: Route_Handler) #expand {
    register_parsed(router, "DELETE", #run parse_or_report(pattern), handler);
}

head :: (router: *Router, $pattern: string, handler: Route_Handler) #expand {
    register_parsed(router, "HEAD", #run parse_or_report(pattern), handler);
}
```

Leave `route()` (immediately below them) unchanged — it stays the runtime/dynamic escape hatch and still calls `build_partial_tree` + `merge`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — `test_macro_head` and `test_macro_route_equivalence` pass, AND every existing dispatch/middleware/mount test still passes (they call `get`/`post` with literal patterns, which now expand the macro): `test_dispatch_basic`, `test_dispatch_404`, `test_dispatch_405`, `test_dispatch_method_filtering`, `test_dispatch_param_access`, `test_dispatch_wildcard`, `test_middleware_chain`, `test_middleware_short_circuit`, `test_mount_basic`, `test_mount_404`, `test_mount_middleware_order`, `test_context_http_set`. All six suites green.

- [ ] **Step 7: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/router.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'feat(http_router): compile-time route macros (get/post/put/http_delete/head)\n\nThe method helpers are now #expand macros that #run parse_or_report over the\nliteral pattern (malformed -> compiler_report build error) and register at\nruntime via register_parsed -> existing merge. head is new. route() stays the\nruntime/dynamic escape hatch. Existing dispatch tests pass unchanged.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: Verify examples + manual compile-error check

**Files:** none modified (verification only; see Step 3 for a throwaway check).

- [ ] **Step 1: Build every example** — confirms the namespaced macro calls (`http_router.get(...)`) in the examples expand and compile.

Run: `~/jai/jai/bin/jai-linux first.jai -`
Expected: `hello_world`, `hello_world_raw`, `app_state` build into `build_debug/` with no errors.

- [ ] **Step 2: Smoke-test the routed example**

Run:
```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
./build_release/hello_world &
SRV=$!
curl -s --retry 10 --retry-connrefused --retry-delay 1 -o /dev/null -w "%{http_code}\n" http://localhost:9090/        # expect 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9090/missing  # expect 404
kill $SRV
```
Expected: `200` then `404`.

- [ ] **Step 3: Manually verify the compile-time error path** (the one thing the green suite can't assert). Create a throwaway example `examples/_bad_route.jai` that registers a malformed pattern through a macro:

```jai
// throwaway — verifies a malformed pattern fails the BUILD via compiler_report
main :: () {
    server: Server;
    router: http_router.Router;
    http_router.get(*router, "/a/*rest/b", bad);   // '*' not last -> must fail compilation
}
bad :: (req: *Request, resp: *Response) {}
#import "http_server"()(Handler_Data = http_router.Router);
http_router :: #import "http_router";
```

Run: `~/jai/jai/bin/jai-linux first.jai - _bad_route`
Expected: **build FAILS** with the message `http_router: '*' wildcard must be the last segment in pattern '/a/*rest/b'`.
Then delete the throwaway: `rm examples/_bad_route.jai` (leaving it would break `first.jai -`, which compiles every example).

- [ ] **Step 4: Full suite (release) + cleanup confirip**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests -release`
Expected: all six suites green.
Confirm `examples/_bad_route.jai` is gone (`git status` clean apart from any intended doc edits).

- [ ] **Step 5: Update docs + commit** — update CLAUDE.md's status to note the route macros (compile-time malformed-pattern errors), bump the `http_router` test count (it gains the `parse_pattern` + macro tests), and mark the route-macros design doc implemented. Then:

```bash
git add -A
git commit -m "$(printf 'docs: route macros landed (compile-time pattern validation)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Self-Review

**Spec coverage:**
- `Pattern_Segment` + baked `[]` slice (no wrapper/MAX/count) → Task 1 ✓
- `parse_pattern` shared by compile time + runtime → Task 1 (defined), Task 2 (`#run` via `parse_or_report`) ✓
- `build_partial_tree` refactor preserving its tests → Task 1 ✓
- five method macros (`get/post/put/http_delete/head`) + `#run parse_or_report` + `register_parsed` → Task 2 ✓
- compile-time `compiler_report` vs runtime `log_error` split → `parse_or_report` (Task 2) / `build_partial_tree` (Task 1) ✓
- `route()` retained as runtime escape hatch → unchanged (stated Task 2 Step 5) ✓
- equivalence (macro vs `route()`) tested → Task 2 ✓; examples build + manual compile-error check → Task 3 ✓
- Out of scope (correctly absent): generic `handle`, `options`/`patch`, compile-time duplicate detection.

**Placeholder scan:** none — every code step is complete; commands have expected output.

**Type consistency:** `Pattern_Segment{kind,name}`, `parse_pattern -> ([]Pattern_Segment, bool, string)`, `chain_from_segments(method, []Pattern_Segment, handler) -> Trie`, `parse_or_report(string) -> []Pattern_Segment`, `register_parsed(*Router, string, []Pattern_Segment, Route_Handler)`, macros `(*Router, $string, Route_Handler)` — consistent across tasks and call sites. `merge`/`trie_add_node`/`substr`/`Seg_Kind`/`Trie` reused as defined in the trie module. The macros pass the `#run` result inline (no named constant) per the global constraint — matches `register_parsed`'s `segs` parameter.

**Index discipline:** `chain_from_segments` re-resolves `t.nodes[cur]` after each `trie_add_node` (mirrors the audited `build_partial_tree`); noted in Global Constraints and the function comment.
