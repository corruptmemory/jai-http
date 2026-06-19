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
//   ++            end of our args; everything after is passed to the run target,
//                 and the presence of `++` implies -run
//   <name>        a build target → examples/<name>.jai
//
//   first.jai -                            build ALL examples/*.jai (debug, no run)
//   first.jai - hello_world                build one example (debug, no run)
//   first.jai - hello_world -release       → build_release/hello_world
//   first.jai - hello_world -run           build + run (debug)
//   first.jai - hello_world ++ --port 9090 build + run, passthrough (`++` implies -run)
//   first.jai - run-tests                  build + run all suites (debug)
//   first.jai - run-tests -release         same, optimized
//
// Why `++` and not `--` as the passthrough separator: the Jai compiler reserves a
// standalone `--` for its OWN developer options — everything after the last `--` is
// consumed by the compiler and never reaches compile_time_command_line. `++` is an
// ordinary token that passes straight through, as do `--`-PREFIXED args after it
// (e.g. `--port`); only a *standalone* `--` is special, so don't forward one.
// ─────────────────────────────────────────────────────────────────────────────

build :: () {
    set_working_directory(#filepath);

    // first.jai has no `main`, so the compiler's implicit target workspace must not
    // emit an executable. Set this ONCE up front so EVERY path below — arg errors,
    // the no-arg build-all, build-only, and run — is covered (how_to/400_workspaces).
    set_build_options_dc(.{do_output = false});

    args := get_build_options().compile_time_command_line;

    // Split at the FIRST `++`: tokens after it are passthrough to the run target, and
    // the presence of `++` implies -run. The `++` token itself is consumed.
    front := args;
    passthrough: [] string;
    saw_separator := false;
    for args {
        if it == "++" {
            saw_separator = true;
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

    run := run_flag || saw_separator;   // `++` implies -run

    if run_tests_flag {
        if targets.count > 0 {
            compiler_report(tprint("`run-tests` is exclusive; it cannot be combined with build targets (got %).\n", targets));
            return;
        }
        if saw_separator {
            compiler_report("`run-tests` takes no `++` passthrough (`++` is only for running a single example).\n");
            return;
        }
        // -run alongside run-tests is a no-op (tests always run); allowed silently.
        run_tests(optimized);
        return;
    }

    if run {
        if targets.count == 0 {
            compiler_report("`-run` (or `++`) needs exactly one build target, but none was given.\n");
            return;
        }
        if targets.count > 1 {
            compiler_report(tprint("`-run` (or `++`) needs exactly one build target, but % were given: %.\n", targets.count, targets));
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
    build_and_run_test("router_tests",   "router_tests",   "modules/http_router/tests/test.jai", "build_tests", optimized);
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
