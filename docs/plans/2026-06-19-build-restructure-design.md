# Build Restructure Design

**Date:** 2026-06-19
**Status:** Approved
**Files:** `first.jai`, `server/` → `examples/`, remove `client/`, `CLAUDE.md`, `README.md`

## Goal

Refocus the project from a client/server pair to a **library + examples** layout, and
replace the bespoke `debug`/`release`/`test` build verbs with a small, principled
build-target grammar modeled on the informal conventions in
`~/projects/jai-wayland/first.jai` and `~/projects/game-bootstrap/first.jai`.

Two driving decisions:

1. **No native HTTP client.** A from-scratch client (TLS, HTTP/2, HTTP/3/QUIC, redirects,
   cookies, proxies, cert chains) is a multi-year correctness tarpit that libcurl already
   owns. The client will become a thin libcurl wrapper (a future, separate module). This
   change merely *removes* the native client; it does not add the wrapper.
2. **Examples, not a single server program.** `server/main.jai` becomes
   `examples/hello_world.jai`. The repo can grow more examples by dropping files into
   `examples/` — no `first.jai` edits required.

## Section 1: Project layout changes

- **Delete** `client/` (its `main.jai` is an empty stub) and the `client` workspace.
- **`git mv server/ examples/`**, then **`git mv examples/main.jai examples/hello_world.jai`**
  (history preserved). File contents are unchanged: it imports `http_server` and serves
  Hello-World on `0.0.0.0:9090`.
- `.gitignore` already ignores `build_debug/`, `build_release/`, `build_tests/` — no change.

## Section 2: Argument grammar

Invocation: `~/jai/jai/bin/jai-linux first.jai - [tokens…]`. Tokens (after the compiler's
`-` separator) are classified **by shape, not position**, so modifiers and targets may
interleave freely.

| Token            | Meaning                                                                 |
|------------------|-------------------------------------------------------------------------|
| `-release`       | build mode = OPTIMIZED (the **only** mode modifier)                     |
| `-run`           | autorun the single build target                                        |
| `run-tests`      | the exclusive test verb                                                |
| `++`             | end of first.jai args; everything after is passthrough to the run target (**implies `-run`**) |
| any other bare word | a build target → `examples/<word>.jai`                              |

- **Debug is the default and implied** — there is no `-debug` token. Build mode is a single
  boolean (`optimized := false`, flipped by `-release`). The old "both `-debug` and
  `-release`" contradiction is **structurally impossible** — nothing to resolve, nothing to
  get wrong. (No-silent-failures: the bad combination is unrepresentable, not merely rejected.)
- Any **unrecognized `-flag`** before `++` is a hard error listing valid modifiers.
- **Passthrough separator is `++`, not `--`.** A standalone `--` is reserved by the Jai
  compiler for its own developer options — everything after the last `--` is consumed by the
  compiler and never reaches `compile_time_command_line`. `++` passes straight through to the
  metaprogram (as do `--`-*prefixed* tokens after it, e.g. `--port`); only a *standalone* `--`
  is special, so a literal `--` cannot be forwarded to the run target (a nonissue in practice).

## Section 3: Dispatch & validation

```
split tokens at the FIRST `++`  → (front, passthrough)
classify front into: optimized (bool), run_flag (bool), run_tests_flag (bool), targets[]
run := run_flag OR (saw `++`)                   // `++` implies -run

if run_tests_flag:
    error if targets present          ("run-tests is exclusive; cannot combine with targets …")
    error if passthrough present       ("run-tests takes no passthrough args")
    ignore -run                         (no-op)
    → build + run all test suites in <mode> into build_tests/
else if run:
    error unless exactly one target     (0 → "nothing to run"; ≥2 → "-run/`++` needs a single target")
    → build that target into build_<mode>/, then run it with passthrough args
else:
    if targets empty → build ALL examples/*.jai into build_<mode>/ (run none)   // the no-arg default
    else             → build each named target into build_<mode>/ (run none)
```

Error conditions (all hard, via `compiler_report`, no silent acceptance):
- `run-tests` combined with any build target, or with `++`/passthrough.
- `-run` (or `++`) with zero targets, or with ≥2 targets.
- A named target whose `examples/<name>.jai` does not exist (error lists discovered examples).
- An unrecognized `-flag`.

## Section 4: Target resolution (dynamic)

- Named target `foo` → `examples/foo.jai`; if `!file_exists`, error and list `examples/*.jai`.
- "Build all" enumerates `examples/` via `file_list`, keeps `*.jai`.
- Executable name = `path_strip_extension(path_filename(path))`; output to `build_debug/<name>`
  or `build_release/<name>`.

## Section 5: Output directories

- Debug → `build_debug/<name>`
- Release → `build_release/<name>`
- Tests → `build_tests/<name>` (always; `-release` only changes optimization, not the dir)

Keeping the `build_debug`/`build_release` split lets debug and release binaries coexist
(the benchmark workflow builds release while a debug build may linger) and matches the
existing `.gitignore`.

## Section 6: Helper shape (refactor of `first.jai`)

- `set_build_options_dc(.{do_output = false})` **once at the top** of `build()` — covers
  every path (errors, no-arg build-all, build-only, run), per the game-bootstrap idiom.
  `first.jai` has no `main`, so its implicit workspace must not emit an executable.
- `build_example(name: string, optimized: bool, run: bool, passthrough: [] string)` —
  one workspace, `modules/` prepended to `import_path`,
  `copy_commonly_propagated_fields(get_build_options(), *opts)` so `-no_color` etc. reach
  the child. `compiler_begin_intercept` + wait for `Message_Complete` so a compile error
  `exit(1)`s (fail-fast, needed both for the build-all compile-gate and before running).
  When `run`, after a successful build, `run_command(tprint("build_%/%", dir, name), ..passthrough)`
  — `Autorun.run_build_result_of_workspace` can't forward args, so `run_command` is used.
- `build_all_examples(optimized: bool)` — `file_list("examples")`, filter `.jai`, call
  `build_example(name, optimized, run=false, .[])` per file. Error if `examples/` is empty.
- `run_tests(optimized: bool)` — the existing five `build_and_run_test` calls
  (`http_server`, `datetime`, `channel`, `csv`, `json`), parameterized by optimization.

## Section 7: Documentation ripple (part of this change)

- **CLAUDE.md**: Build Commands (new grammar + `run-tests`), Architecture "Entry points"
  (drop client; `server/main.jai` → `examples/hello_world.jai`), Benchmarking
  (`./build_release/server` → `./build_release/hello_world`), and a note recording the
  "client = libcurl wrapper, not native" decision.
- **README.md**: build/run instructions.

## Resulting usage

```bash
jai-linux first.jai -                                 # build ALL examples (debug, no run)
jai-linux first.jai - hello_world                     # build one example (debug, no run)
jai-linux first.jai - hello_world -release            # → build_release/hello_world
jai-linux first.jai - hello_world -run                # build + run (debug)
jai-linux first.jai - hello_world ++ --port 9090      # build + run, passthrough (`++` implies -run)
jai-linux first.jai - hello_world -run -release       # build + run, optimized
jai-linux first.jai - hello_world foo bar             # build three, run none
jai-linux first.jai - run-tests                       # build + run all suites (debug)
jai-linux first.jai - run-tests -release              # same, optimized
```

## Out of scope

- The libcurl client wrapper module (future, separate work).
- Any change to the HTTP server library itself or the test suites' contents.
