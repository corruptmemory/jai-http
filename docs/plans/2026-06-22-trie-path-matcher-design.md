# Trie-Based Path Matcher (segment trie, merge-built)

**Date:** 2026-06-22
**Status:** Implemented (2026-06-22) — phases A+B landed; `match_pattern` retired; all suites green. Phase C (macros) is future work.
**Module:** `modules/http_router/`
**Supersedes routing internals of:** `modules/http_router/router.jai` (the `routes:[MAX_ROUTES]Route`
linear array + `match_pattern` linear scan)

## Goal

Replace the router's O(route-count) linear dispatch — today `dispatch` scans every route calling
`match_pattern` until one matches (`router.jai`) — with a **segment trie** that matches in
O(path-segments), independent of route count. This is the optimization CLAUDE.md's benchmark notes
already name ("the real routing cost is O(route count)… the radix-tree / compiled-dispatch target").

The trie is built by **merging** per-route partial trees into one accumulated tree. We deliberately
keep an intermediate "partial tree" artifact (chi performs the same union with no intermediate) because
it buys two things:

1. **`merge` becomes a pure, isolated, testable primitive** — `(tree, tree) -> tree` — so the whole
   router is morally `fold(merge, map(build_partial_tree, routes))`.
2. **A free `tree -> string` dump** for debugging the accumulated structure.

### Why these building blocks (the macro endgame)

The eventual integration (a **separate, later effort — NOT this work**) turns `get`/`post`/`head`/
`put`/`http_delete`/… into `#expand` macros that `#run` the pattern parse and the conflict-detecting
`merge`-check at **compile time** over the literal pattern, threading the runtime handler and folding
into the router at runtime (the handler is a function pointer, so it can't be a compile-time constant —
but the *structure* and the *conflict check* don't need the handler value, only the path+method).
Because `build_partial_tree` and `merge` are plain functions that run identically at compile time
(`#run`) or runtime, hoisting them into macros **turns today's runtime route errors into compile-time
errors** — a malformed pattern or a duplicate route fails the *build*. This design therefore builds the *building blocks* the macros will
later reshape; it contains **no metaprogramming**. The one spot with real Jai-macro uncertainty is
deferred to that future effort, where it will be validated against the `jai-language` skill first.

## Scope

- **Segment trie only.** Nodes are `/`-delimited segments. No byte-level radix/prefix compression and
  **no intra-segment params** (`:id.json`). This leaves some performance on the table (accepted); the
  byte-radix generalization is a possible future optimization, not this work.
- **Semantics preserved exactly** from the current matcher: literal segments match verbatim; `:name`
  matches one non-empty segment and captures it; `*name` matches the rest of the path (greedy) and must
  be the last segment.
- **Public API unchanged** (`get`/`post`/`put`/`http_delete`/`route`, `use`, `mount`, `param`, `serve`,
  `route_handler`, `dispatch`). Examples and tests should barely move.

### In scope vs out of scope (the segment boundary)

The matcher splits on `/` and classifies each segment *as a whole* by its first character — literal,
`:param`, or `*wildcard`. A param captures **exactly one entire segment**; you cannot mix fixed text
and a capture *inside* one segment. The dividing line: **does any single `/`-segment contain both fixed
text and a capture (or two captures)?** Yes → out of scope.

**In scope** (every segment is purely literal, purely one `:param`, or the trailing `*wildcard`):

| Pattern | Notes |
|---|---|
| `/`, `/users`, `/users/new` | root / literal segments |
| `/users/:id` | whole-segment param; matches `/users/123`, not `/users/` or `/users/1/2` |
| `/users/:id/posts/:postId` | multiple params, each its own segment |
| `/files/*path` | wildcard = rest-of-path (slashes included), must be last |
| `/download/:filename` → `report.csv` | whole segment incl. the dot captured as `filename`; we just can't *anchor* `.csv` |
| `/users/new` + `/users/:id` together | static-vs-param at the same position → resolved by the backtracking walk |

**Out of scope** (a param sharing a segment with fixed text or another param — needs chi's `tail` byte):

| Pattern | Why it's out |
|---|---|
| `/files/:name.json` | literal `.json` suffix after a param in one segment. Our parser would read the name as `name.json` and capture the whole segment — **silently wrong, not an error**. |
| `/users/:first-:last` | two params + a `-` separator in one segment |
| `/v:version/users` | literal prefix before a param in a segment |
| `/{id:[0-9]+}` | regexp-constrained params (a chi feature we never had) |

**Gap handling:** covered in user-level handler code (capture the whole segment, e.g. `:file` →
`report.json`, and strip the extension in the handler; or use `*wildcard`), or revisit if a byte-radix
upgrade is ever pursued.

## Data model — segment trie, index-based

Index-based flat node array (child references are `s32` indices, `-1` = none). Chosen because it is
POD — it serializes for the dump trivially, matches the module's existing fixed-array/count house style,
is allocation-free per node, and is the shape the future macro needs for a compile-time-constant partial
tree (no rewrite later).

```jai
Seg_Kind :: enum u8 { STATIC; PARAM; WILDCARD; }

// A leaf endpoint, one per HTTP method registered at a node. Mirrors chi's `endpoint`.
Endpoint :: struct {
    method:     string;          // "GET", "POST", … ; "" = any method
    handler:    Route_Handler;
    param_keys: [] string;       // ordered capture names for the route ending here (views into pattern)
}

Node :: struct {
    kind:            Seg_Kind;   // STATIC | PARAM | WILDCARD
    segment:         string;     // STATIC: the literal segment text. PARAM/WILDCARD: debug-only name
                                 //   (the matcher never reads it — see "capture model").
    static_children: ...;        // indices of STATIC child nodes (searched by segment compare)
    param_child:     s32;        // -1, or the single PARAM child index
    wildcard_child:  s32;        // -1, or the single WILDCARD child index
    endpoints:       ...;        // array of Endpoint searched by method; non-empty => this is a leaf
}

Tree :: struct {
    nodes: ...;                  // node[0] is the root: kind STATIC, empty segment
}
```

Exact storage policy (fixed-capacity arrays via new module params like `MAX_NODES` vs dynamic `[..]`)
is an implementation-plan decision. Either way the tree is **built once at registration/startup and is
read-only during dispatch** — allocation is never on the per-request hot path.

### Capture model — positional values, names at the leaf ("model b", confirmed in chi source)

Param and wildcard **nodes are anonymous** to the matcher: at each node there is at most **one** param
child and **one** wildcard child, so there is no "which param" to disambiguate structurally. Capture
**values** are collected **positionally** during the walk; capture **names** (`param_keys`) live on the
**leaf endpoint** and are zipped with the values once a match is confirmed. This is exactly what chi
does (`tree.go:350` stores `paramKeys` on the endpoint; `tree.go:458`/`497` push values positionally;
`tree.go:465` appends keys at the leaf; `context.go` exposes the parallel `Keys`/`Values` arrays).

`param_keys` is per-endpoint (per-method), not per-node, so `GET /users/:id` and `POST /users/:userId`
— which share a structural leaf but differ in capture name — both work. The node's `segment` field for
PARAM/WILDCARD nodes holds the name **only for the dump**; matching ignores it.

## The three primitives (this work)

### `build_partial_tree(method, pattern, handler) -> Tree`

Parse a single pattern into its (linear-chain) partial tree: split on `/`, classify each segment
(literal / `:name` / `*name`), and produce root → … → leaf. The leaf carries one `Endpoint` with the
method, handler, and the ordered `param_keys` extracted from the `:`/`*` segments. Runs unchanged at
compile time (future macro, via `#run`) or runtime (the `route()` registration path). Rejects malformed
patterns (e.g. `*name` not last) loudly.

### `merge(into: *Tree, from: Tree) -> (ok: bool)`  — the core primitive

Structural union walked from both roots: equal-segment STATIC children recurse; the single PARAM child
is shared and recursed; the WILDCARD child is shared; at a leaf the **method-maps are unioned**. Because
captures are positional and names live at the leaf, merging param/wildcard edges is purely structural —
no name reconciliation.

The **only** conflict is **same structural path + same method** registered twice. Policy: **loud error,
not silent overwrite** (chi silently last-wins; that violates this project's "no silent failures"
discipline). At runtime `merge` reports failure via `log_error` (and the registration path may hard-fail
startup); the same detection becomes a **compile-time error** once it runs inside the future macro.
Differing param *names* on the same structural path are **not** a conflict (they land on per-method
endpoints).

For a single-route partial tree (always a chain) `merge` reduces to "insert this path," but it stays
general (tree × tree) so future mount-by-merge is possible.

### `tree_to_string(tree) -> string`  — debug dump

Walk the tree depth-indented, printing each node's kind + segment (`:name` / `*name` for param/wildcard
via the debug `segment` field) and, at leaves, the methods and their `param_keys`. Generalizes for free
to a **forest** (`for roots: tree_to_string`), which is the "dump a forest" nicety. Used in tests and
when debugging merges.

## Dispatch / match (this work)

`tree_match(tree, method, path) -> (handler, param_keys, values, status)` walks the path
segment-by-segment with chi's **precedence + backtracking** (`tree.go:483-539`):

1. Try the **STATIC** child whose segment equals the current path segment.
2. Else try the **PARAM** child (capture the segment value positionally).
3. Else try the **WILDCARD** child (capture the rest of the path; terminal).
4. If the chosen branch **dead-ends deeper**, **reset the captured values for that branch and fall back**
   to the next alternative. This recursive-with-backtrack walk (e.g. `/users/new` static vs `/users/:id`
   param) is the one real correctness landmine, so it gets the heaviest tests.

On reaching the path end at a leaf: if the leaf has an endpoint for the method → **match** (zip
`param_keys` with the positional values into the existing `HTTP_Context.params`); if the leaf exists but
lacks the method → **405**; if no leaf → **404**. This preserves the current 405-vs-404 behavior.

The router holds **one tree**, with method handled at the leaf (chi-style — clean 405). `param(name)`
keeps its current signature and reads the zipped params from `context.http`.

## Integration & what does NOT change here

- **`route()`** (runtime registration) becomes: `build_partial_tree` → `merge` into `router`'s tree.
  `get`/`post`/… stay thin wrappers over `route()` (they become macros only in the future effort).
- **`dispatch`** swaps its `match_pattern` linear scan for `tree_match`; `HTTP_Context`, middleware
  chain walking (`proceed`/`use`), and `param` are otherwise untouched.
- **`mount`** keeps its **current prefix-delegation** behavior (not merge-under-prefix) — merging
  sub-trees would muddy per-mount middleware scoping; defer.
- **`match_pattern`** remains (and stays tested) until `tree_match` replaces its use in `dispatch`; it
  may then be retired or kept as a reference.
- The **cast-free `route_handler`/`serve`** machinery and `Handler_Data` wiring are unaffected.

## Phasing

- **Phase A — primitive:** `Tree`/`Node`/`Endpoint`, `build_partial_tree`, `merge`, `tree_to_string`.
  Pure functions, TDD'd in total isolation (this is the user's "phase 1 + phase 2").
- **Phase B — match:** `tree_match` with precedence/backtracking + positional capture; wire into
  `dispatch`/`param`; 405/404. Registration stays runtime (`route()` builds partial + merges).
- **Phase C — (separate, later) macros + benchmark:** hoist `get`/… to `#expand` macros (compile-time
  `build_partial_tree`, runtime `merge`), validating the macro/compile-time-constant mechanism against
  the `jai-language` skill first; benchmark A/B — the real win is **many-routes scaling** vs today's
  O(routes) scan, plus single-route overhead parity.

## Testing

- **Phase A:** table-driven tests for `build_partial_tree` (segment classification, param-key
  extraction, malformed-pattern rejection); `merge` in isolation (disjoint paths, shared prefixes,
  shared param edges, method-map union, **duplicate path+method → error**); `tree_to_string` snapshots.
- **Phase B:** match tests emphasizing **backtracking** (static-vs-param at the same position, wildcard
  fallthrough), multi-param capture + zip, wildcard rest-of-path, 404 vs 405. Reuse/port the existing 20
  `http_router` suite assertions so behavior is provably preserved.
- All via `~/jai/jai/bin/jai-linux first.jai - run-tests`. MANDATORY before writing any Jai: invoke the
  `jai-language` skill.

## Open/explicit decisions (blessed)

1. Duplicate path+method = **loud error** (not chi's silent last-wins).
2. `mount` stays **prefix-delegation** for now (no merge-under-prefix).
3. **Index-based flat-array** nodes from the start (so the future macro's compile-time-constant tree
   needs no rewrite).
