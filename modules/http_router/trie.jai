
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

// Structurally union `from` into `into`. Returns false on a duplicate (same path + same method),
// after logging — never a silent overwrite. For a single-route partial tree this is "insert".
merge :: (into: *Trie, from: Trie) -> bool {
    trie_ensure_root(into);
    if from.nodes.count == 0  return true;
    return trie_merge_node(into, 0, from, 0);
}

// Depth-indented dump of a tree. Generalizes to a forest by calling it per root.
tree_to_string :: (t: Trie) -> string {
    sb: Basic.String_Builder;
    Basic.init_string_builder(*sb);
    if t.nodes.count > 0  trie_dump_node(*sb, t, 0, 0);
    return Basic.builder_to_string(*sb);
}

// -- Private helpers --

#scope_module

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
