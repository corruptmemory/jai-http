
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
