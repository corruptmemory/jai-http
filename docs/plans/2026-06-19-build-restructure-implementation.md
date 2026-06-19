# Build Restructure Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. This is a
> build-metaprogram refactor; "tests" are concrete `first.jai` invocations with expected
> outcomes rather than unit tests.

**Goal:** Replace the client/server build with a library+examples layout and a shape-based
build-target grammar in `first.jai`.

**Architecture:** `first.jai` parses `compile_time_command_line` tokens by shape (`-release`,
`-run`, `run-tests`, `--`, bare-word targets), resolves targets dynamically to
`examples/<name>.jai`, and builds into `build_debug/` or `build_release/` (tests into
`build_tests/`). Debug is the implied default; `-release` is the only mode modifier.

**Tech Stack:** Jai compile-time metaprogramming (`Compiler`, `Autorun`), `File`/`File_Utilities`
(`file_list`, `file_exists`, `make_directory_if_it_does_not_exist`), `String` (`begins_with`,
`ends_with`, `path_filename`, `path_strip_extension`), `Process` (`run_command`).

## Global Constraints

- Jai beta 0.2.029. Build via `~/jai/jai/bin/jai-linux first.jai - <args>` only.
- Single dash `-` separates compiler args from metaprogram args.
- `modules/` is prepended to every workspace's `import_path` (ours-first).
- `set_build_options_dc(.{do_output = false})` exactly once, at the top of `build()`.
- All error paths use `compiler_report(...)` (mode defaults to `Report.ERROR` → non-zero exit).
- No native client. The client becomes a future libcurl wrapper (out of scope here).

---

### Task 1: Layout + build grammar (atomic — one green commit)

Moving files without rewriting `first.jai` would break the build (old `first.jai` references
`server/main.jai` + `client/main.jai`), so the move and the rewrite are one commit.

**Files:**
- Delete: `client/main.jai` (and the now-empty `client/` dir)
- Move: `server/main.jai` → `examples/hello_world.jai`
- Rewrite: `first.jai`

**Interfaces produced (helpers in `first.jai`):**
- `available_examples() -> [] string` — example basenames (sans `.jai`) in `examples/`.
- `build_example(name: string, optimized: bool, run: bool, passthrough: [] string)`
- `build_all_examples(optimized: bool)`
- `build_and_run_test(workspace_name, executable_name, test_file, build_dir: string, optimized: bool)`
- `run_tests(optimized: bool)`

- [ ] **Step 1: Move/delete sources (preserve history)**

```bash
cd /home/jim/projects/jai-http
git rm -r client
git mv server examples
git mv examples/main.jai examples/hello_world.jai
```

Expected: `examples/hello_world.jai` exists; `server/` and `client/` gone.

- [ ] **Step 2: Rewrite `first.jai`** with exactly this content:

```jai
#run,stallable build();

// ─────────────────────────────────────────────────────────────────────────────
// Build metaprogram for jai-http.
//
//   ~/jai/jai/bin/jai-linux first.jai - [tokens…]
//
// Tokens are classified by SHAPE, not position (modifiers and targets interleave):
//   -release      build optimized (default is debug; there is NO -debug token)
//   -run          run the single build target after building
//   run-tests     build + run all unit-test suites (exclusive: no other targets)
//   --            end of our args; everything after is passed to the run target,
//                 and the presence of `--` implies -run
//   <name>        a build target → examples/<name>.jai
//
//   first.jai -                            build ALL examples/*.jai (debug, no run)
//   first.jai - hello_world                build one example (debug, no run)
//   first.jai - hello_world -release       → build_release/hello_world
//   first.jai - hello_world -run           build + run (debug)
//   first.jai - hello_world -- --port 9090 build + run, passthrough (`--` implies -run)
//   first.jai - run-tests                  build + run all suites (debug)
//   first.jai - run-tests -release         same, optimized
// ─────────────────────────────────────────────────────────────────────────────

build :: () {
    set_working_directory(#filepath);

    // first.jai has no `main`, so the compiler's implicit target workspace must not
    // emit an executable. Set this ONCE up front so EVERY path below — arg errors,
    // the no-arg build-all, build-only, and run — is covered (how_to/400_workspaces).
    set_build_options_dc(.{do_output = false});

    args := get_build_options().compile_time_command_line;

    // Split at the FIRST `--`: tokens after it are passthrough to the run target, and
    // the presence of `--` implies -run. The `--` token itself is consumed.
    front := args;
    passthrough: [] string;
    saw_double_dash := false;
    for args {
        if it == "--" {
            saw_double_dash = true;
            front       = array_view(args, 0, it_index);
            passthrough = array_view(args, it_index + 1, args.count - it_index - 1);
            break;
        }
    }

    optimized      := false;
    run_flag       := false;
    run_tests_flag := false;
    targets: [..] string;

    for arg: front {
        if arg == {
          case "-release";  optimized      = true;
          case "-run";      run_flag       = true;
          case "run-tests"; run_tests_flag = true;
          case;
            if begins_with(arg, "-") {
                compiler_report(tprint("Unknown modifier '%'. Valid modifiers: '-release', '-run'; verb: 'run-tests'; bare words are build targets (examples/<name>.jai).\n", arg));
                return;
            }
            array_add(*targets, arg);
        }
    }

    run := run_flag || saw_double_dash;   // `--` implies -run

    if run_tests_flag {
        if targets.count > 0 {
            compiler_report(tprint("`run-tests` is exclusive; it cannot be combined with build targets (got %).\n", targets));
            return;
        }
        if saw_double_dash {
            compiler_report("`run-tests` takes no `--` passthrough (`--` is only for running a single example).\n");
            return;
        }
        // -run alongside run-tests is a no-op (tests always run); allowed silently.
        run_tests(optimized);
        return;
    }

    if run {
        if targets.count == 0 {
            compiler_report("`-run` (or `--`) needs exactly one build target, but none was given.\n");
            return;
        }
        if targets.count > 1 {
            compiler_report(tprint("`-run` (or `--`) needs exactly one build target, but % were given: %.\n", targets.count, targets));
            return;
        }
        build_example(targets[0], optimized, run = true, passthrough);
        return;
    }

    if targets.count == 0 {
        build_all_examples(optimized);   // no-arg default: compile-gate every example
        return;
    }

    for target: targets  build_example(target, optimized, run = false, .[]);
}

// All example basenames discovered in examples/ (sans .jai), for build-all and errors.
available_examples :: () -> [] string {
    names: [..] string;
    for file_list("examples") {
        if ends_with(it, ".jai")  array_add(*names, path_strip_extension(path_filename(it)));
    }
    return names;
}

build_all_examples :: (optimized: bool) {
    names := available_examples();
    if names.count == 0 {
        compiler_report("No examples found (expected at least one examples/*.jai).\n");
        return;
    }
    for names  build_example(it, optimized, run = false, .[]);
}

build_example :: (name: string, optimized: bool, run: bool, passthrough: [] string) {
    source := tprint("examples/%.jai", name);
    if !file_exists(source) {
        compiler_report(tprint("No example named '%' (looked for %). Available examples: %.\n", name, source, available_examples()));
        return;
    }

    build_dir := ifx optimized then "build_release" else "build_debug";

    w := compiler_create_workspace(name);
    if !w { print("% workspace creation failed.\n", name); return; }

    opts := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *opts);

    import_path: [..] string;
    array_add(*import_path, "modules");
    array_add(*import_path, ..opts.import_path);
    opts.import_path = import_path;

    if optimized  set_optimization(*opts, .OPTIMIZED);
    else          set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name    = name;
    opts.output_path               = build_dir;
    make_directory_if_it_does_not_exist(build_dir);
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    add_build_file(source, w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
          case .COMPLETE;
            mc := cast(*Message_Complete) message;
            if mc.error_code != .NONE  exit(1);
            break;
        }
    }
    compiler_end_intercept(w);

    if run {
        command: [..] string;
        array_add(*command, tprint("%/%", build_dir, name));
        for passthrough  array_add(*command, it);
        result := run_command(.. command);
        if result.exit_code != 0  exit(result.exit_code);
    }
}

build_and_run_test :: (workspace_name: string, executable_name: string, test_file: string, build_dir: string, optimized: bool) {
    w := compiler_create_workspace(workspace_name);
    if !w { print("% workspace creation failed.\n", workspace_name); return; }

    opts := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *opts);

    import_path: [..] string;
    array_add(*import_path, "modules");
    array_add(*import_path, ..opts.import_path);
    opts.import_path = import_path;

    if optimized  set_optimization(*opts, .OPTIMIZED);
    else          set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name    = executable_name;
    opts.output_path               = build_dir;
    make_directory_if_it_does_not_exist(build_dir);
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    add_build_file(test_file, w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
          case .COMPLETE;
            mc := cast(*Message_Complete) message;
            if mc.error_code != .NONE  exit(1);
            break;
        }
    }
    compiler_end_intercept(w);
    Autorun.run_build_result_of_workspace(w);
}

run_tests :: (optimized: bool) {
    build_and_run_test("tests",          "tests",          "modules/http_server/tests/test.jai", "build_tests", optimized);
    build_and_run_test("datetime_tests", "datetime_tests", "modules/datetime/tests/test.jai",     "build_tests", optimized);
    build_and_run_test("channel_tests",  "channel_tests",  "modules/channel/tests/test.jai",      "build_tests", optimized);
    build_and_run_test("csv_tests",      "csv_tests",      "modules/csv/tests/test.jai",          "build_tests", optimized);
    build_and_run_test("json_tests",     "json_tests",     "modules/json/tests/test.jai",         "build_tests", optimized);
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
Autorun :: #import "Autorun";
```

- [ ] **Step 3: Verify build-all (no-arg default)**

Run: `~/jai/jai/bin/jai-linux first.jai -`
Expected: exit 0; `build_debug/hello_world` exists (`test -x build_debug/hello_world`).

- [ ] **Step 4: Verify single target + `-release`**

Run: `~/jai/jai/bin/jai-linux first.jai - hello_world -release`
Expected: exit 0; `build_release/hello_world` exists.

- [ ] **Step 5: Verify `run-tests`**

Run: `~/jai/jai/bin/jai-linux first.jai - run-tests`
Expected: exit 0; all five suites build and run; pass summaries print
(`70 http_server`, `19 datetime`, `15 channel`, `15 csv`, plus the JSON leak harness `0 bytes leaked`).

- [ ] **Step 6: Verify error paths (each must exit non-zero and print the message)**

```bash
~/jai/jai/bin/jai-linux first.jai - run-tests hello_world   # "run-tests is exclusive"
~/jai/jai/bin/jai-linux first.jai - -run                    # "needs exactly one build target, but none"
~/jai/jai/bin/jai-linux first.jai - a b -run                # "2 were given"
~/jai/jai/bin/jai-linux first.jai - nope                    # "No example named 'nope'"
~/jai/jai/bin/jai-linux first.jai - -bogus                  # "Unknown modifier '-bogus'"
~/jai/jai/bin/jai-linux first.jai - run-tests -- x          # "run-tests takes no `--` passthrough"
```

Expected: each prints its message and exits non-zero (`echo $status` ≠ 0 in fish).

- [ ] **Step 7: Verify `-run` plumbing (server blocks, so background + curl + kill)**

```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -run &
sleep 6                                   # allow build + listen
curl -s http://localhost:9090/            # expect: Hello, World!
kill %1 2>/dev/null; wait 2>/dev/null
```

Expected: `curl` prints `Hello, World!`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Restructure build: examples layout + shape-based target grammar

Drop the native client (future libcurl wrapper) and the client/server split.
server/main.jai -> examples/hello_world.jai. first.jai now parses build targets
by shape (-release, -run, run-tests, --, bare-word examples), resolves targets
dynamically to examples/<name>.jai, and builds into build_debug/ or build_release/.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Documentation

**Files:**
- Modify: `CLAUDE.md` (Build Commands, Architecture entry points, Benchmarking, decision note)
- Modify: `README.md` (build/run instructions)

- [ ] **Step 1: Update `CLAUDE.md` Build Commands** — replace the `debug`/`release`/`test`
  block with the new grammar and the usage table from the design doc; show `run-tests`
  builds the five suites into `build_tests/`.

- [ ] **Step 2: Update `CLAUDE.md` Architecture "Entry points"** — remove `client/main.jai`;
  change `server/main.jai` to `examples/hello_world.jai`; add a one-line note: "Native HTTP
  client dropped in favor of a future libcurl wrapper — curl already owns client correctness."

- [ ] **Step 3: Update `CLAUDE.md` Benchmarking** — `./build_release/server` →
  `./build_release/hello_world`; build line `first.jai - release` → `first.jai - hello_world -release`.

- [ ] **Step 4: Update `README.md`** — build/run instructions to match the new grammar.

- [ ] **Step 5: Verify docs reference no stale paths**

Run: `grep -rnE "build_release/server|build_debug/server|client/main|first.jai - (debug|release|test)\b" CLAUDE.md README.md`
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update build/run instructions for examples layout

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** §1 layout → Task 1 Step 1; §2 grammar + §3 dispatch → Task 1 Step 2 (full
`build()`); §4 dynamic resolution → `available_examples`/`build_example`; §5 output dirs →
`build_dir` selection + `build_tests`; §6 helpers → Task 1 Step 2; §7 docs → Task 2. All covered.

**Placeholder scan:** Task 1 contains the complete `first.jai`. Task 2 steps describe doc edits
in prose (acceptable — prose docs, not code), with a grep gate proving no stale paths remain.

**Type consistency:** `build_example(name, optimized, run, passthrough)` and
`build_and_run_test(..., optimized)` signatures are used identically wherever called;
`available_examples() -> [] string` consumed by `build_all_examples` and the error message.
