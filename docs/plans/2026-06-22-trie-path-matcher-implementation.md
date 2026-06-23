# Trie-Based Path Matcher Implementation Plan

> **STATUS: COMPLETE (2026-06-22).** Phases A (trie types, `build_partial_tree`, `tree_to_string`, `merge`) and B (`tree_match` + dispatch integration) landed and were reviewed task-by-task plus a clean whole-branch review. Optional Task B4 (retire `match_pattern`) was also done. All six suites green; `hello_world` smoke-tested 200/404 live. Phase C (the `get`/`post`/… macros) is future work, intentionally out of this plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `http_router`'s O(route-count) linear dispatch with a segment trie matched in O(path-segments), built by merging per-route partial trees into one accumulated tree.

**Architecture:** A new `modules/http_router/trie.jai` holds an index-based segment trie (`Trie` = flat array of `Trie_Node`, children referenced by `s32` index). Three pure primitives — `build_partial_tree` (parse one pattern → chain), `merge` (structural union of two trees, the testable core), `tree_to_string` (debug dump) — plus a backtracking `tree_match`. `Router` swaps its `routes:[MAX_ROUTES]Route` linear array for a `tree: Trie`; `route()` becomes build+merge; `dispatch`/`dispatch_with_middleware` swap their `match_pattern` scan for `tree_match`. Capture model "(b)": param/wildcard nodes are anonymous, capture **values** are collected positionally during the walk, capture **names** (`param_keys`) live on the leaf endpoint and are zipped at match time.

**Tech Stack:** Jai (beta 0.2.029), `modules/http_router/` layered on `modules/http_server/`. Build/test via the `first.jai` metaprogram.

**Design doc:** `docs/plans/2026-06-22-trie-path-matcher-design.md` (read it first).

## Global Constraints

- **MANDATORY before writing/modifying ANY Jai code:** invoke the `jai-language` skill. Not optional, applies to every task and any subagent.
- **Jai version:** beta 0.2.029. Build with `~/jai/jai/bin/jai-linux first.jai - <args>`. Never call `go build`/`jai`-directly-for-output outside the metaprogram.
- **Run all tests:** `~/jai/jai/bin/jai-linux first.jai - run-tests` (the `http_router` suite is `modules/http_router/tests/test.jai`). A suite passes when it prints its final "All … tests passed." line and the process exits 0.
- **`http_router` imports `Basic` NAMED** (`Basic :: #import "Basic"` in `module.jai`). So inside module files (`trie.jai`, `router.jai`) every Basic call needs the `Basic.` prefix (`Basic.array_add`, `Basic.log_error`, `Basic.init_string_builder`, `Basic.append`, `Basic.builder_to_string`, `Basic.String_Builder`, `Basic.NewArray`, `Basic.temp`). `string_equals` comes from `http_server` (module-visible, no prefix). **Test files import `Basic` anonymously** — bare `assert`/`print` there.
- **No per-request allocation on the hot path.** The trie is built once at registration/startup (default allocator) and is **read-only** during dispatch. Per-request match uses only stack locals.
- **No silent failures.** Registration/build problems are reported via `Basic.log_error`; `merge` returns `ok: bool`.
- **INDEX DISCIPLINE (critical correctness rule).** `Trie.nodes` is a dynamic array; appending a node may reallocate it, invalidating any `*Trie_Node`. **Never hold a `*Trie_Node` across a call that can append** (`trie_add_node`, `trie_copy_subtree`, `trie_merge_node`). In build/merge/copy code, always re-resolve `t.nodes[idx]` after such calls and work with `s32` indices. (The matcher is read-only and may hold node pointers freely.)
- **Format Jai with `gofmt`-equivalent:** match surrounding style (the module's existing 4-space, aligned-declaration style).
- **Commits:** commit per task (messages end with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer). Do NOT push unless the user asks.

---

## File Structure

- **Create `modules/http_router/trie.jai`** — all trie types and primitives: `Seg_Kind`, `Trie_Endpoint`, `Trie_Node`, `Trie`, `Match_Status`; `build_partial_tree`, `merge`, `tree_to_string`, `tree_match`; private helpers (`trie_add_node`, `trie_copy_subtree`, `trie_merge_node`, `trie_match_rec`, `split_path_segments`, `peel`/`substr`, `find_static_child`, `node_has_method`, `find_endpoint`, `find_endpoint_method`, `trie_ensure_root`, `trie_dump_node`).
- **Modify `modules/http_router/module.jai`** — add `#load "trie.jai";` (before `#load "router.jai";`); add `MAX_PATH_SEGMENTS` param; remove `MAX_ROUTES` param.
- **Modify `modules/http_router/router.jai`** — change `Router` struct (drop `routes`/`route_count`, add `tree: Trie`); remove the `Route` struct; rewrite `route()` (build+merge); rewrite `dispatch` and `dispatch_with_middleware` to use `tree_match`. Leave `match_pattern`, middleware (`use`/`proceed`), `mount`, `param`, `HTTP_Context`, the cast-free `route_handler`/`serve` untouched.
- **Modify `modules/http_router/tests/test.jai`** — add trie-primitive tests (Phase A) and tree-match tests (Phase B); call them from `main`. Existing dispatch/mount/middleware tests must keep passing unchanged.

---

## Phase A — the trie primitive (pure, isolated)

### Task A1: Trie types + `build_partial_tree`

**Files:**
- Create: `modules/http_router/trie.jai`
- Modify: `modules/http_router/module.jai` (add `#load "trie.jai";`, add `MAX_PATH_SEGMENTS`)
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Produces (used by all later tasks):
  - `Seg_Kind :: enum u8 { STATIC; PARAM; WILDCARD; }`
  - `Trie_Endpoint :: struct { method: string; handler: Route_Handler; param_keys: [] string; }`
  - `Trie_Node :: struct { kind: Seg_Kind; segment: string; static_children: [..] s32; param_child: s32; wildcard_child: s32; endpoints: [..] Trie_Endpoint; }`
  - `Trie :: struct { nodes: [..] Trie_Node; }`
  - `build_partial_tree :: (method: string, pattern: string, handler: Route_Handler) -> (tree: Trie, ok: bool)`
  - private: `trie_add_node :: (t: *Trie, kind: Seg_Kind, segment: string) -> s32`, `substr :: (s: string, start: s64, len: s64) -> string`

- [ ] **Step 1: Add `#load` and module param.** Edit `modules/http_router/module.jai`: add `MAX_PATH_SEGMENTS : s32 = 32,` to the `#module_parameters (...)` list, and add `#load "trie.jai";` immediately before `#load "router.jai";`. (Keep `MAX_ROUTES` for now — `router.jai` still uses it via `Router.routes` until Task B2 removes the linear route array. Removing it here would break the build.)

Resulting `#module_parameters` block:
```jai
#module_parameters (
    MAX_ROUTES         : s32 = 128,
    MAX_PARAMS         : s32 = 8,
    MAX_MIDDLEWARE     : s32 = 16,
    MAX_MOUNTS         : s32 = 16,
    MAX_PATH_SEGMENTS  : s32 = 32
);
```
Resulting load lines (bottom of `module.jai`):
```jai
#load "trie.jai";
#load "router.jai";
```

- [ ] **Step 2: Write the failing test** in `modules/http_router/tests/test.jai` (add above the `main` proc, e.g. after the wildcard tests):

```jai
// -- Trie: build_partial_tree --

test_build_simple_param :: () {
    t, ok := build_partial_tree("GET", "/users/:id", simple_test_handler);
    assert(ok, "build should succeed");
    assert(t.nodes.count == 3, "expected 3 nodes, got %", t.nodes.count);
    assert(t.nodes[0].kind == .STATIC && t.nodes[0].segment.count == 0, "node0 = root STATIC \"\"");
    assert(t.nodes[1].kind == .STATIC && string_equals(t.nodes[1].segment, "users"), "node1 = STATIC users");
    assert(t.nodes[2].kind == .PARAM  && string_equals(t.nodes[2].segment, "id"),    "node2 = PARAM id");
    assert(t.nodes[0].static_children.count == 1 && t.nodes[0].static_children[0] == 1, "root -> node1");
    assert(t.nodes[1].param_child == 2, "node1 param_child -> node2");
    assert(t.nodes[2].endpoints.count == 1, "leaf has 1 endpoint");
    assert(string_equals(t.nodes[2].endpoints[0].method, "GET"), "endpoint method GET");
    assert(t.nodes[2].endpoints[0].param_keys.count == 1, "1 param key");
    assert(string_equals(t.nodes[2].endpoints[0].param_keys[0], "id"), "param key = id");
    print("  PASS: test_build_simple_param\n");
}

test_build_root :: () {
    t, ok := build_partial_tree("GET", "/", simple_test_handler);
    assert(ok, "build / should succeed");
    assert(t.nodes.count == 1, "root-only tree, got % nodes", t.nodes.count);
    assert(t.nodes[0].endpoints.count == 1, "root is the leaf for /");
    print("  PASS: test_build_root\n");
}

test_build_wildcard :: () {
    t, ok := build_partial_tree("GET", "/static/*filepath", simple_test_handler);
    assert(ok, "build wildcard should succeed");
    assert(t.nodes.count == 3, "root, static, wildcard");
    assert(t.nodes[2].kind == .WILDCARD && string_equals(t.nodes[2].segment, "filepath"), "node2 wildcard filepath");
    assert(t.nodes[1].wildcard_child == 2, "static -> wildcard");
    assert(string_equals(t.nodes[2].endpoints[0].param_keys[0], "filepath"), "key filepath");
    print("  PASS: test_build_wildcard\n");
}

test_build_wildcard_not_last :: () {
    _, ok := build_partial_tree("GET", "/a/*rest/b", simple_test_handler);
    assert(!ok, "wildcard not last must fail");
    print("  PASS: test_build_wildcard_not_last\n");
}
```

Add to `main` (in a new section before "All http_router tests passed."):
```jai
    print("\nTrie - build_partial_tree:\n");
    test_build_simple_param();
    test_build_root();
    test_build_wildcard();
    test_build_wildcard_not_last();
```

- [ ] **Step 3: Run test to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: FAIL — `build_partial_tree` (and `Trie`) undefined / `trie.jai` not found until created.

- [ ] **Step 4: Write `modules/http_router/trie.jai`**

```jai

// Segment trie for HTTP path routing. Index-based: a Trie is a flat array of nodes; children are
// referenced by s32 index (-1 = none). Built once at registration (default allocator) and READ-ONLY
// during dispatch. See docs/plans/2026-06-22-trie-path-matcher-design.md.
//
// INDEX DISCIPLINE: appending to `Trie.nodes` may reallocate it. Never hold a *Trie_Node across an
// append (trie_add_node / trie_copy_subtree / trie_merge_node) — re-resolve t.nodes[idx] afterward.
// The matcher (trie_match_rec) is read-only and may hold node pointers freely.

Seg_Kind :: enum u8 {
    STATIC   :: 0;
    PARAM    :: 1;
    WILDCARD :: 2;
}

// One HTTP method's leaf data. param_keys are ordered capture names (views into the pattern literal),
// zipped with positionally-captured values at match time. "" method = any method.
Trie_Endpoint :: struct {
    method:     string;
    handler:    Route_Handler;
    param_keys: [] string;
}

Trie_Node :: struct {
    kind:            Seg_Kind;
    segment:         string;        // STATIC: literal text. PARAM/WILDCARD: name (debug only; the matcher ignores it).
    static_children: [..] s32;      // indices into the owning Trie.nodes
    param_child:     s32 = -1;      // single PARAM child, or -1
    wildcard_child:  s32 = -1;      // single WILDCARD child, or -1
    endpoints:       [..] Trie_Endpoint;   // non-empty => this node is a leaf
}

Trie :: struct {
    nodes: [..] Trie_Node;   // nodes[0] is the root: STATIC, empty segment
}

Match_Status :: enum u8 {
    MATCHED            :: 0;
    METHOD_NOT_ALLOWED :: 1;
    NOT_FOUND          :: 2;
}

// Parse one pattern into its (linear-chain) partial tree. ok=false on malformed pattern (e.g. a
// non-terminal wildcard), after logging. Runs identically at compile time or runtime.
build_partial_tree :: (method: string, pattern: string, handler: Route_Handler) -> (tree: Trie, ok: bool) {
    t: Trie;
    trie_add_node(*t, .STATIC, "");   // root at index 0
    ok := true;

    keys: [..] string;
    cur: s32 = 0;
    saw_wildcard := false;

    // Strip leading '/', then split the remainder on '/'. "" remainder => zero segments (root is leaf).
    rem := pattern;
    if rem.count > 0 && rem[0] == #char "/" { rem.data += 1; rem.count -= 1; }

    if rem.count > 0 {
        i := 0;
        n := rem.count;
        while i <= n {
            j := i;
            while j < n && rem[j] != #char "/"  j += 1;
            seg := substr(rem, i, j - i);

            if saw_wildcard {
                Basic.log_error("http_router: '*' wildcard must be the last segment in pattern '%'", pattern);
                ok = false;
                break;
            }

            if seg.count > 0 && seg[0] == #char ":" {
                name  := substr(seg, 1, seg.count - 1);
                child := trie_add_node(*t, .PARAM, name);
                t.nodes[cur].param_child = child;
                Basic.array_add(*keys, name);
                cur = child;
            } else if seg.count > 0 && seg[0] == #char "*" {
                name  := substr(seg, 1, seg.count - 1);
                child := trie_add_node(*t, .WILDCARD, name);
                t.nodes[cur].wildcard_child = child;
                Basic.array_add(*keys, name);
                cur = child;
                saw_wildcard = true;
            } else {
                child := trie_add_node(*t, .STATIC, seg);
                Basic.array_add(*t.nodes[cur].static_children, child);
                cur = child;
            }

            if j >= n  break;
            i = j + 1;
        }
    }

    if ok {
        ep: Trie_Endpoint;
        ep.method     = method;
        ep.handler    = handler;
        ep.param_keys = keys;
        Basic.array_add(*t.nodes[cur].endpoints, ep);
    }

    return t, ok;
}

// -- Private helpers --

#scope_module

trie_add_node :: (t: *Trie, kind: Seg_Kind, segment: string) -> s32 {
    node: Trie_Node;
    node.kind           = kind;
    node.segment        = segment;
    node.param_child    = -1;
    node.wildcard_child = -1;
    Basic.array_add(*t.nodes, node);
    return cast(s32) (t.nodes.count - 1);
}

substr :: (s: string, start: s64, len: s64) -> string {
    out: string = ---;
    out.data  = s.data + start;
    out.count = len;
    return out;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — the four new `Trie - build_partial_tree` tests print PASS; all other suites stay green.

- [ ] **Step 6: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/module.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'feat(http_router): trie types + build_partial_tree\n\nIndex-based segment trie (flat node array) and a parser that turns one\npattern into its partial chain, with positional-capture names on the leaf\nendpoint. Phase A of the trie path matcher.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task A2: `tree_to_string` (debug dump)

**Files:**
- Modify: `modules/http_router/trie.jai`
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Consumes: `Trie`, `build_partial_tree` (Task A1).
- Produces: `tree_to_string :: (t: Trie) -> string`; private `trie_dump_node :: (sb: *Basic.String_Builder, t: Trie, node_idx: s32, depth: s32)`.

- [ ] **Step 1: Write the failing test** (add to `tests/test.jai`):

```jai
// -- Trie: tree_to_string --

test_tree_dump :: () {
    t, ok := build_partial_tree("GET", "/users/:id", simple_test_handler);
    assert(ok);
    s := tree_to_string(t);
    expected := "STATIC \"\"\n  STATIC \"users\"\n    :id GET\n";
    assert(string_equals(s, expected), "dump mismatch:\n%", s);
    print("  PASS: test_tree_dump\n");
}
```

Add to `main`:
```jai
    print("\nTrie - tree_to_string:\n");
    test_tree_dump();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: FAIL — `tree_to_string` undefined.

- [ ] **Step 3: Implement** — append to `trie.jai` (the public proc near the other public procs, the helper in the `#scope_module` region):

Public proc (place above `#scope_module`):
```jai
// Depth-indented dump of a tree. Generalizes to a forest by calling it per root.
tree_to_string :: (t: Trie) -> string {
    sb: Basic.String_Builder;
    Basic.init_string_builder(*sb);
    if t.nodes.count > 0  trie_dump_node(*sb, t, 0, 0);
    return Basic.builder_to_string(*sb);
}
```

Helper (in the `#scope_module` region):
```jai
trie_dump_node :: (sb: *Basic.String_Builder, t: Trie, node_idx: s32, depth: s32) {
    node := t.nodes[node_idx];
    for 0..depth-1  Basic.append(sb, "  ");
    if node.kind == {
      case .STATIC;   Basic.append(sb, "STATIC \""); Basic.append(sb, node.segment); Basic.append(sb, "\"");
      case .PARAM;    Basic.append(sb, ":");         Basic.append(sb, node.segment);
      case .WILDCARD; Basic.append(sb, "*");         Basic.append(sb, node.segment);
    }
    for node.endpoints {
        Basic.append(sb, " ");
        if it.method.count == 0  Basic.append(sb, "ANY");
        else                     Basic.append(sb, it.method);
    }
    Basic.append(sb, "\n");
    for node.static_children    trie_dump_node(sb, t, it, depth + 1);
    if node.param_child    != -1  trie_dump_node(sb, t, node.param_child,    depth + 1);
    if node.wildcard_child != -1  trie_dump_node(sb, t, node.wildcard_child, depth + 1);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — `test_tree_dump` prints PASS.

- [ ] **Step 5: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'feat(http_router): tree_to_string debug dump\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task A3: `merge` (structural union + conflict detection)

**Files:**
- Modify: `modules/http_router/trie.jai`
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Consumes: `Trie`, `build_partial_tree`, `tree_to_string`, `trie_add_node`, `substr` (A1/A2).
- Produces: `merge :: (into: *Trie, from: Trie) -> bool`; private `trie_ensure_root :: (t: *Trie)`, `trie_merge_node :: (into: *Trie, into_idx: s32, from: Trie, from_idx: s32) -> bool`, `trie_copy_subtree :: (into: *Trie, from: Trie, from_idx: s32) -> s32`, `find_static_child :: (t: *Trie, node_idx: s32, seg: string) -> s32`, `find_endpoint_method :: (t: *Trie, node_idx: s32, method: string) -> bool`.

- [ ] **Step 1: Write the failing tests** (add to `tests/test.jai`):

```jai
// -- Trie: merge --

test_merge_disjoint :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET", "/users", simple_test_handler);
    p2, _ := build_partial_tree("GET", "/posts", simple_test_handler);
    assert(merge(*acc, p1), "merge p1");
    assert(merge(*acc, p2), "merge p2");
    s := tree_to_string(acc);
    expected := "STATIC \"\"\n  STATIC \"users\" GET\n  STATIC \"posts\" GET\n";
    assert(string_equals(s, expected), "disjoint merge:\n%", s);
    print("  PASS: test_merge_disjoint\n");
}

test_merge_shared_prefix :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET", "/users/:id",          simple_test_handler);
    p2, _ := build_partial_tree("GET", "/users/:userId/posts", simple_test_handler);
    assert(merge(*acc, p1));
    assert(merge(*acc, p2));
    // Shared "users" + shared single param edge; p2 continues to "posts".
    s := tree_to_string(acc);
    expected := "STATIC \"\"\n  STATIC \"users\"\n    :id GET\n      STATIC \"posts\" GET\n";
    assert(string_equals(s, expected), "shared-prefix merge:\n%", s);
    print("  PASS: test_merge_shared_prefix\n");
}

test_merge_method_union :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET",  "/x", simple_test_handler);
    p2, _ := build_partial_tree("POST", "/x", simple_test_handler);
    assert(merge(*acc, p1));
    assert(merge(*acc, p2));
    s := tree_to_string(acc);
    expected := "STATIC \"\"\n  STATIC \"x\" GET POST\n";
    assert(string_equals(s, expected), "method-union merge:\n%", s);
    print("  PASS: test_merge_method_union\n");
}

test_merge_conflict :: () {
    acc: Trie;
    p1, _ := build_partial_tree("GET", "/dup", simple_test_handler);
    p2, _ := build_partial_tree("GET", "/dup", simple_test_handler);
    assert(merge(*acc, p1), "first registration ok");
    assert(!merge(*acc, p2), "duplicate GET /dup must conflict");
    print("  PASS: test_merge_conflict\n");
}
```

Add to `main`:
```jai
    print("\nTrie - merge:\n");
    test_merge_disjoint();
    test_merge_shared_prefix();
    test_merge_method_union();
    test_merge_conflict();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: FAIL — `merge` undefined.

- [ ] **Step 3: Implement** — public `merge` above `#scope_module`; helpers inside it.

Public:
```jai
// Structurally union `from` into `into`. Returns false on a duplicate (same path + same method),
// after logging — never a silent overwrite. For a single-route partial tree this is "insert".
merge :: (into: *Trie, from: Trie) -> bool {
    trie_ensure_root(into);
    if from.nodes.count == 0  return true;
    return trie_merge_node(into, 0, from, 0);
}
```

Helpers (in `#scope_module`):
```jai
trie_ensure_root :: (t: *Trie) {
    if t.nodes.count == 0  trie_add_node(t, .STATIC, "");
}

find_static_child :: (t: *Trie, node_idx: s32, seg: string) -> s32 {
    node := *t.nodes[node_idx];
    for node.static_children {
        if string_equals(t.nodes[it].segment, seg)  return it;
    }
    return -1;
}

find_endpoint_method :: (t: *Trie, node_idx: s32, method: string) -> bool {
    node := *t.nodes[node_idx];
    for * node.endpoints  if string_equals(it.method, method)  return true;
    return false;
}

// Deep-copy from's subtree rooted at from_idx into `into`; returns the new index in `into`.
// INDEX DISCIPLINE: re-resolve into.nodes[new_idx] after each recursive copy (which grows into.nodes).
trie_copy_subtree :: (into: *Trie, from: Trie, from_idx: s32) -> s32 {
    new_idx := trie_add_node(into, from.nodes[from_idx].kind, from.nodes[from_idx].segment);

    feps := from.nodes[from_idx].endpoints;          // header copy (reads from-backing)
    for feps  Basic.array_add(*into.nodes[new_idx].endpoints, it);

    fkids := from.nodes[from_idx].static_children;   // header copy
    for fkids {
        child := trie_copy_subtree(into, from, it);
        Basic.array_add(*into.nodes[new_idx].static_children, child);
    }
    if from.nodes[from_idx].param_child != -1 {
        c := trie_copy_subtree(into, from, from.nodes[from_idx].param_child);
        into.nodes[new_idx].param_child = c;
    }
    if from.nodes[from_idx].wildcard_child != -1 {
        c := trie_copy_subtree(into, from, from.nodes[from_idx].wildcard_child);
        into.nodes[new_idx].wildcard_child = c;
    }
    return new_idx;
}

trie_merge_node :: (into: *Trie, into_idx: s32, from: Trie, from_idx: s32) -> bool {
    ok := true;

    // 1. endpoints union (conflict on same method)
    feps := from.nodes[from_idx].endpoints;          // header copy
    for feps {
        if find_endpoint_method(into, into_idx, it.method) {
            Basic.log_error("http_router: duplicate route — method '%' already registered at this path", it.method);
            ok = false;
        } else {
            Basic.array_add(*into.nodes[into_idx].endpoints, it);
        }
    }

    // 2. static children
    fkids := from.nodes[from_idx].static_children;   // header copy
    for fkids {
        cf       := it;
        cseg     := from.nodes[cf].segment;
        existing := find_static_child(into, into_idx, cseg);
        if existing != -1 {
            if !trie_merge_node(into, existing, from, cf)  ok = false;
        } else {
            ni := trie_copy_subtree(into, from, cf);
            Basic.array_add(*into.nodes[into_idx].static_children, ni);
        }
    }

    // 3. param child (single)
    if from.nodes[from_idx].param_child != -1 {
        fp := from.nodes[from_idx].param_child;
        if into.nodes[into_idx].param_child != -1 {
            if !trie_merge_node(into, into.nodes[into_idx].param_child, from, fp)  ok = false;
        } else {
            ni := trie_copy_subtree(into, from, fp);
            into.nodes[into_idx].param_child = ni;
        }
    }

    // 4. wildcard child (single)
    if from.nodes[from_idx].wildcard_child != -1 {
        fw := from.nodes[from_idx].wildcard_child;
        if into.nodes[into_idx].wildcard_child != -1 {
            if !trie_merge_node(into, into.nodes[into_idx].wildcard_child, from, fw)  ok = false;
        } else {
            ni := trie_copy_subtree(into, from, fw);
            into.nodes[into_idx].wildcard_child = ni;
        }
    }

    return ok;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — the four `Trie - merge` tests print PASS. (`test_merge_conflict` emits a `log_error` line about a duplicate — that is expected and does NOT fail the suite.)

- [ ] **Step 5: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'feat(http_router): trie merge with conflict detection\n\nStructural union of two segment tries: shared static/param/wildcard edges,\nleaf method-map union, loud error (not silent overwrite) on duplicate\npath+method. The associative primitive the router folds over.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Phase B — match + dispatch integration

### Task B1: `tree_match` (backtracking walk + positional capture)

**Files:**
- Modify: `modules/http_router/trie.jai`
- Test: `modules/http_router/tests/test.jai`

**Interfaces:**
- Consumes: `Trie`, `Match_Status`, `build_partial_tree`, `merge`, `find_static_child` (A1–A3); `Param`/`MAX_PARAMS`/`Route_Handler`/`string_equals` (existing module/core).
- Produces: `tree_match :: (t: *Trie, method: string, path: string, out_params: *[MAX_PARAMS] Param, out_count: *s32) -> (handler: Route_Handler, status: Match_Status)`; private `split_path_segments :: (sp: string, segs: *[MAX_PATH_SEGMENTS] string) -> (count: s32, ok: bool)`, `trie_match_rec :: (t: *Trie, node_idx: s32, sp: string, segs: [] string, k: s32, method: string, values: *[MAX_PARAMS] string, vcount: *s32, saw_leaf: *bool) -> s32`, `node_has_method :: (node: *Trie_Node, method: string) -> bool`, `find_endpoint :: (node: *Trie_Node, method: string) -> *Trie_Endpoint`.

- [ ] **Step 1: Write the failing tests** (add to `tests/test.jai`). These build an accumulated tree via `build_partial_tree`+`merge`, then drive `tree_match` directly:

```jai
// -- Trie: tree_match --

build_acc :: (patterns: [] string) -> Trie {
    acc: Trie;
    for patterns {
        p, ok := build_partial_tree("GET", it, simple_test_handler);
        assert(ok, "build % ok", it);
        assert(merge(*acc, p), "merge % ok", it);
    }
    return acc;
}

test_tm_static_vs_param_backtrack :: () {
    acc := build_acc(.["/users/new", "/users/:id"]);
    params: type_of(HTTP_Context.params);
    pc: s32;

    // Static wins for the literal.
    h, st := tree_match(*acc, "GET", "/users/new", *params, *pc);
    assert(st == .MATCHED, "static /users/new matched");
    assert(pc == 0, "static path captures nothing");

    // Param matches a different value.
    h, st = tree_match(*acc, "GET", "/users/42", *params, *pc);
    assert(st == .MATCHED, "param /users/42 matched");
    assert(pc == 1 && string_equals(params[0].name, "id") && string_equals(params[0].value, "42"), "id=42");

    print("  PASS: test_tm_static_vs_param_backtrack\n");
}

test_tm_deeper_backtrack :: () {
    // /users/new is a leaf; /users/:id/edit needs the param branch even though "new" is static.
    acc := build_acc(.["/users/new", "/users/:id/edit"]);
    params: type_of(HTTP_Context.params);
    pc: s32;
    h, st := tree_match(*acc, "GET", "/users/new/edit", *params, *pc);
    assert(st == .MATCHED, "must backtrack from static 'new' to param branch");
    assert(pc == 1 && string_equals(params[0].value, "new"), "captured id=new, got '%'", params[0].value);
    print("  PASS: test_tm_deeper_backtrack\n");
}

test_tm_wildcard :: () {
    acc := build_acc(.["/static/*filepath"]);
    params: type_of(HTTP_Context.params);
    pc: s32;
    h, st := tree_match(*acc, "GET", "/static/css/app.css", *params, *pc);
    assert(st == .MATCHED, "wildcard matched");
    assert(pc == 1 && string_equals(params[0].name, "filepath"), "key filepath");
    assert(string_equals(params[0].value, "css/app.css"), "rest captured, got '%'", params[0].value);

    h, st = tree_match(*acc, "GET", "/static/", *params, *pc);
    assert(st == .NOT_FOUND, "empty wildcard remainder must not match");
    print("  PASS: test_tm_wildcard\n");
}

test_tm_404_405 :: () {
    acc: Trie;
    p, _ := build_partial_tree("GET", "/only", simple_test_handler);
    merge(*acc, p);
    params: type_of(HTTP_Context.params);
    pc: s32;

    h, st := tree_match(*acc, "GET", "/missing", *params, *pc);
    assert(st == .NOT_FOUND, "missing path -> NOT_FOUND");

    h, st = tree_match(*acc, "POST", "/only", *params, *pc);
    assert(st == .METHOD_NOT_ALLOWED, "wrong method on existing path -> METHOD_NOT_ALLOWED");

    print("  PASS: test_tm_404_405\n");
}
```

Add to `main`:
```jai
    print("\nTrie - tree_match:\n");
    test_tm_static_vs_param_backtrack();
    test_tm_deeper_backtrack();
    test_tm_wildcard();
    test_tm_404_405();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: FAIL — `tree_match` undefined.

- [ ] **Step 3: Implement** — public `tree_match` above `#scope_module`; helpers inside it.

Public:
```jai
// Match method+path against the tree. Fills out_params/out_count (capture names from the matched
// leaf zipped with positionally-captured values). Read-only over the tree; uses only stack locals.
tree_match :: (t: *Trie, method: string, path: string, out_params: *[MAX_PARAMS] Param, out_count: *s32) -> (handler: Route_Handler, status: Match_Status) {
    out_count.* = 0;
    null_handler: Route_Handler;
    if t.nodes.count == 0  return null_handler, .NOT_FOUND;

    sp := path;
    if sp.count > 0 && sp[0] == #char "/" { sp.data += 1; sp.count -= 1; }

    segs_buf: [MAX_PATH_SEGMENTS] string;
    seg_count, ok := split_path_segments(sp, *segs_buf);
    if !ok  return null_handler, .NOT_FOUND;

    segs: [] string;
    segs.data  = segs_buf.data;
    segs.count = seg_count;

    values: [MAX_PARAMS] string;
    vcount: s32 = 0;
    saw_leaf := false;

    leaf := trie_match_rec(t, 0, sp, segs, 0, method, *values, *vcount, *saw_leaf);
    if leaf != -1 {
        ep := find_endpoint(*t.nodes[leaf], method);
        if ep != null {
            n := vcount;
            if n > cast(s32) ep.param_keys.count  n = cast(s32) ep.param_keys.count;
            for i: 0..n-1 {
                out_params.*[i].name  = ep.param_keys[i];
                out_params.*[i].value = values[i];
            }
            out_count.* = n;
            return ep.handler, .MATCHED;
        }
    }
    if saw_leaf  return null_handler, .METHOD_NOT_ALLOWED;
    return null_handler, .NOT_FOUND;
}
```

Helpers (in `#scope_module`):
```jai
// Split the leading-slash-stripped path on '/'. Empty pieces (trailing/double slash) are kept as
// empty segments, matching build_partial_tree. ok=false if there are more than MAX_PATH_SEGMENTS.
split_path_segments :: (sp: string, segs: *[MAX_PATH_SEGMENTS] string) -> (count: s32, ok: bool) {
    count: s32 = 0;
    if sp.count == 0  return 0, true;
    i := 0;
    n := sp.count;
    while i <= n {
        j := i;
        while j < n && sp[j] != #char "/"  j += 1;
        if count >= MAX_PATH_SEGMENTS  return count, false;
        segs.*[count] = substr(sp, i, j - i);
        count += 1;
        if j >= n  break;
        i = j + 1;
    }
    return count, true;
}

node_has_method :: (node: *Trie_Node, method: string) -> bool {
    for * node.endpoints  if it.method.count == 0 || string_equals(it.method, method)  return true;
    return false;
}

find_endpoint :: (node: *Trie_Node, method: string) -> *Trie_Endpoint {
    for * node.endpoints  if string_equals(it.method, method)  return it;   // exact method
    for * node.endpoints  if it.method.count == 0              return it;   // then "any"
    return null;
}

// Precedence static -> param -> wildcard, with backtracking. Returns the matched leaf index, or -1.
// `sp` is the stripped path (for wildcard raw-remainder capture); `segs[k..]` are the unconsumed segments.
trie_match_rec :: (t: *Trie, node_idx: s32, sp: string, segs: [] string, k: s32, method: string,
                   values: *[MAX_PARAMS] string, vcount: *s32, saw_leaf: *bool) -> s32 {
    node := *t.nodes[node_idx];

    if k == segs.count {
        if node.endpoints.count > 0 {
            saw_leaf.* = true;
            if node_has_method(node, method)  return node_idx;
        }
        return -1;
    }

    seg := segs[k];

    // 1. STATIC
    sidx := find_static_child(t, node_idx, seg);
    if sidx != -1 {
        r := trie_match_rec(t, sidx, sp, segs, k + 1, method, values, vcount, saw_leaf);
        if r != -1  return r;
    }

    // 2. PARAM (non-empty segment only)
    if node.param_child != -1 && seg.count > 0 && vcount.* < MAX_PARAMS {
        values.*[vcount.*] = seg;
        vcount.* += 1;
        r := trie_match_rec(t, node.param_child, sp, segs, k + 1, method, values, vcount, saw_leaf);
        if r != -1  return r;
        vcount.* -= 1;   // backtrack
    }

    // 3. WILDCARD (captures the raw remainder from segs[k] to end of sp; must be non-empty; terminal)
    if node.wildcard_child != -1 && vcount.* < MAX_PARAMS {
        rest: string = ---;
        rest.data  = seg.data;
        rest.count = (sp.data + sp.count) - seg.data;
        if rest.count > 0 {
            values.*[vcount.*] = rest;
            vcount.* += 1;
            wnode := *t.nodes[node.wildcard_child];
            if wnode.endpoints.count > 0 {
                saw_leaf.* = true;
                if node_has_method(wnode, method)  return node.wildcard_child;
            }
            vcount.* -= 1;   // backtrack
        }
    }

    return -1;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — the four `Trie - tree_match` tests print PASS.

- [ ] **Step 5: Commit**

```bash
git add modules/http_router/trie.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'feat(http_router): tree_match with backtracking + positional capture\n\nStatic->param->wildcard precedence with backtracking; positional value\ncapture zipped against leaf param_keys; 404 vs 405 from the leaf method-map.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task B2: Integrate the trie into `Router` / `dispatch`

Atomic change: the `Router` struct loses its linear route array, so `route()`, `dispatch`, and `dispatch_with_middleware` must all switch to the trie in one compilable step. The existing dispatch/mount/middleware tests are the regression gate — they must keep passing **unchanged**.

**Files:**
- Modify: `modules/http_router/router.jai`
- Test: `modules/http_router/tests/test.jai` (existing tests; no new ones required, they regression-guard)

**Interfaces:**
- Consumes: `build_partial_tree`, `merge`, `tree_match`, `Trie`, `Match_Status` (Phase A/B).
- Produces (changed): `Router` now has `tree: Trie` (no `routes`/`route_count`); `route` builds+merges; `dispatch`/`dispatch_with_middleware` use `tree_match`. `Route` struct removed.

- [ ] **Step 1: Run the existing suite to confirm green baseline**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — all suites green (Phase A/B trie tests + the existing router tests).

- [ ] **Step 2: Edit `Router` and remove `Route`** in `router.jai`.

Replace the `Route` struct + `Router` struct (currently `router.jai:29-47`) with:
```jai
Mount_Point :: struct {
    prefix: string;
    router: *Router;
}

Router :: struct {
    tree:        Trie;
    middleware:  [MAX_MIDDLEWARE] Middleware;
    mw_count:    s32;
    mounts:      [MAX_MOUNTS] Mount_Point;
    mount_count: s32;
}
```
(Delete the old `Route :: struct {...}`. Keep `Mount_Point` — shown here because it sat between them.)

Also edit `modules/http_router/module.jai`: remove `MAX_ROUTES : s32 = 128,` from the `#module_parameters (...)` list — it is now unused (Task A1 deliberately kept it because the old `Router.routes` array still referenced it). The remaining params are `MAX_PARAMS`, `MAX_MIDDLEWARE`, `MAX_MOUNTS`, `MAX_PATH_SEGMENTS`.

- [ ] **Step 3: Rewrite `route`** (currently `router.jai:67-74`):
```jai
route :: (router: *Router, method: string, pattern: string, handler: Route_Handler) {
    partial, ok := build_partial_tree(method, pattern, handler);
    if !ok  return;   // build_partial_tree already logged the malformed pattern
    if !merge(*router.tree, partial) {
        Basic.log_error("http_router: route registration conflict for % %", method, pattern);
    }
}
```

- [ ] **Step 4: Rewrite `dispatch`** (currently `router.jai:125-189`) — keep mount delegation first, swap the linear scan for `tree_match`:
```jai
dispatch :: (router: *Router, req: *Request, resp: *Response) {
    // Mounts first — if the path starts with a mount prefix, delegate to the sub-router.
    for i: 0..cast(s64) router.mount_count - 1 {
        mp := *router.mounts[i];
        if starts_with(req.path, mp.prefix) {
            original_path := req.path;
            remaining := req.path;
            remaining.data  += mp.prefix.count;
            remaining.count -= mp.prefix.count;
            if remaining.count == 0  req.path = "/";
            else                     req.path = remaining;
            dispatch_with_middleware(router, mp.router, req, resp);
            req.path = original_path;
            return;
        }
    }

    http_ctx: HTTP_Context;
    handler, status := tree_match(*router.tree, req.method, req.path, *http_ctx.params, *http_ctx.param_count);

    if status == .MATCHED {
        http_ctx.req     = req;
        http_ctx.resp    = resp;
        http_ctx.handler = handler;

        mw_slice: [] Middleware;
        mw_slice.data  = router.middleware.data;
        mw_slice.count = cast(s64) router.mw_count;
        http_ctx.middleware = mw_slice;
        http_ctx.mw_index   = 0;

        ctx := *context;
        ctx.http = *http_ctx;
        push_context ctx.* {
            proceed(*http_ctx);
        }
        return;
    }

    if status == .METHOD_NOT_ALLOWED {
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
        return;
    }

    resp.status_code = 404;
    resp.body = "Not Found";
}
```

- [ ] **Step 5: Rewrite `dispatch_with_middleware`** (currently `router.jai:351-399`) — sub-router matches via its own tree:
```jai
dispatch_with_middleware :: (parent: *Router, sub: *Router, req: *Request, resp: *Response) {
    http_ctx: HTTP_Context;
    handler, status := tree_match(*sub.tree, req.method, req.path, *http_ctx.params, *http_ctx.param_count);

    if status == .MATCHED {
        http_ctx.req     = req;
        http_ctx.resp    = resp;
        http_ctx.handler = handler;

        // Merge middleware: parent first, then sub-router. Temp storage for the merged slice.
        total_mw := cast(s64) parent.mw_count + cast(s64) sub.mw_count;
        if total_mw > 0 {
            merged := Basic.NewArray(total_mw, Middleware, initialized = false,, allocator = Basic.temp);
            for j: 0..cast(s64) parent.mw_count - 1  merged[j] = parent.middleware[j];
            for j: 0..cast(s64) sub.mw_count - 1     merged[cast(s64) parent.mw_count + j] = sub.middleware[j];
            http_ctx.middleware = merged;
        }
        http_ctx.mw_index = 0;

        ctx := *context;
        ctx.http = *http_ctx;
        push_context ctx.* {
            proceed(*http_ctx);
        }
        return;
    }

    if status == .METHOD_NOT_ALLOWED {
        resp.status_code = 405;
        resp.body = "Method Not Allowed";
        return;
    }

    resp.status_code = 404;
    resp.body = "Not Found";
}
```

(Note: `match_pattern` is now unused by `dispatch` but stays defined and tested — its retirement is the optional Task B4.)

- [ ] **Step 6: Run the full suite — regression gate**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: PASS — **all** suites green. Specifically the pre-existing router tests must still pass unchanged: `test_dispatch_basic`, `test_dispatch_404`, `test_dispatch_405`, `test_dispatch_method_filtering`, `test_dispatch_param_access`, `test_dispatch_wildcard`, `test_middleware_chain`, `test_middleware_short_circuit`, `test_mount_basic`, `test_mount_404`, `test_mount_middleware_order`, `test_context_http_set`.

- [ ] **Step 7: Commit**

```bash
git add modules/http_router/router.jai
git commit -m "$(printf 'feat(http_router): dispatch via the segment trie\n\nRouter holds a trie instead of a linear route array; route() builds+merges,\ndispatch/dispatch_with_middleware match via tree_match. O(path) dispatch,\nindependent of route count. Existing router tests pass unchanged.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task B3: Verify examples build + full suite

**Files:** none modified (verification only).

- [ ] **Step 1: Build every example (debug)** — confirms the public API (`get`/`serve`/`mount`/`param`) is unchanged and the three examples still compile against the new internals.

Run: `~/jai/jai/bin/jai-linux first.jai -`
Expected: builds `hello_world`, `hello_world_raw`, `app_state` into `build_debug/` with no errors.

- [ ] **Step 2: Smoke-test the routed example live**

Run:
```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
./build_release/hello_world &
sleep 1
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9090/        # expect 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9090/missing  # expect 404
kill %1
```
Expected: `200` then `404`.

- [ ] **Step 3: Run the full test suite once more (release)**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests -release`
Expected: all six suites green.

- [ ] **Step 4: Commit (docs/status only, if anything changed)** — if nothing changed, skip. Otherwise update CLAUDE.md's router/status notes and the design doc's status, then:
```bash
git add -A
git commit -m "$(printf 'docs: trie path matcher landed (phases A+B)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task B4 (OPTIONAL): Retire `match_pattern`

Only do this with explicit user approval — `match_pattern` and its direct tests currently document the semantics the trie replicates, so keeping them is a valid choice. If retiring:

**Files:**
- Modify: `modules/http_router/router.jai` (delete `match_pattern`), `modules/http_router/tests/test.jai` (delete the `test_match_*` functions, the convenience `match_pattern` overload at the bottom, and their `main` calls).

- [ ] **Step 1:** Delete `match_pattern` (`router.jai:247-322`).
- [ ] **Step 2:** Delete `test_match_exact_path`, `test_match_param_capture`, `test_match_multi_param`, `test_match_no_match`, `test_match_wildcard_basic`, `test_match_wildcard_deep_path`, `test_match_wildcard_with_prefix_params`, `test_match_wildcard_no_match`, the bottom `match_pattern` convenience overload, and their calls in `main`.
- [ ] **Step 3:** Run `~/jai/jai/bin/jai-linux first.jai - run-tests`. Expected: PASS (the trie tests now own matcher coverage).
- [ ] **Step 4:** Commit:
```bash
git add modules/http_router/router.jai modules/http_router/tests/test.jai
git commit -m "$(printf 'refactor(http_router): retire match_pattern (superseded by the trie)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Self-Review

**Spec coverage:**
- Segment-trie data model (index-based, model-(b)) → Task A1 (types) ✓
- `build_partial_tree` → A1 ✓; `merge` + conflict policy → A3 ✓; `tree_to_string` → A2 ✓
- Backtracking `tree_match`, precedence, positional capture, 404/405 → B1 ✓
- Public API unchanged; `route`/`dispatch`/`dispatch_with_middleware` integration; mount stays delegation → B2 ✓
- Examples build / behavior preserved → B3 ✓
- `match_pattern` kept (retirement optional) → B4 ✓
- Out of scope (correctly absent): macros, byte-radix, intra-segment params, merge-under-prefix mounting.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `Trie`/`Trie_Node`/`Trie_Endpoint`/`Seg_Kind`/`Match_Status` defined in A1/A3/B1 and used consistently. `build_partial_tree -> (Trie, bool)`, `merge(*Trie, Trie) -> bool`, `tree_match(*Trie, string, string, *[MAX_PARAMS]Param, *s32) -> (Route_Handler, Match_Status)` — signatures match across tasks and the dispatch call sites in B2. Helper names (`trie_add_node`, `trie_copy_subtree`, `trie_merge_node`, `trie_match_rec`, `split_path_segments`, `find_static_child`, `find_endpoint`, `find_endpoint_method`, `node_has_method`, `substr`, `trie_dump_node`, `trie_ensure_root`) consistent. `MAX_PATH_SEGMENTS` added in A1 and used in B1. ✓

**Index-discipline:** every append-then-reference site (A1 build, A3 copy/merge) re-resolves `t.nodes[idx]` after the appending call; matcher (B1) is read-only. Documented in Global Constraints and inline. ✓
