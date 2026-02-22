
#run,stallable build();

build_sample_programs :: (options: Build_Options, build: string = "debug", build_dir: string = "build_debug") {
    {
        w := compiler_create_workspace("server");
        if !w {
            print("Server workspace creation failed.\n");
            return;
        }

        server_options := get_build_options(w);
        args := server_options.compile_time_command_line;
        import_path: [..] string;
        array_add(*import_path, "modules");
        array_add(*import_path, ..server_options.import_path);
        server_options.import_path = import_path;
        if build == "debug" {
            set_optimization(*server_options, .DEBUG);
        } else {
            set_optimization(*server_options, .OPTIMIZED);
        }
        server_options.arithmetic_overflow_check = .FATAL;
        server_options.output_executable_name = "server";

        server_options.output_path = build_dir;
        make_directory_if_it_does_not_exist(build_dir);
        set_build_options(server_options, w);
        add_build_file("server/main.jai", w);
    }

    {
        w := compiler_create_workspace("client");
        if !w {
            print("Server workspace creation failed.\n");
            return;
        }

        client_options := get_build_options(w);
        args := client_options.compile_time_command_line;
        import_path: [..] string;
        array_add(*import_path, "modules");
        array_add(*import_path, ..client_options.import_path);
        client_options.import_path = import_path;
        if build == "debug" {
            set_optimization(*client_options, .DEBUG);
        } else {
            set_optimization(*client_options, .OPTIMIZED);
        }
        client_options.arithmetic_overflow_check = .FATAL;
        client_options.output_executable_name = "client";

        client_options.output_path = build_dir;
        make_directory_if_it_does_not_exist(build_dir);
        set_build_options(client_options, w);
        add_build_file("client/main.jai", w);
    }

    set_build_options_dc(.{do_output=false});
}

build_and_run_test :: (workspace_name: string, executable_name: string, test_file: string, build_dir: string) {
    w := compiler_create_workspace(workspace_name);
    if !w {
        print("% workspace creation failed.\n", workspace_name);
        return;
    }
    opts := get_build_options(w);
    import_path: [..] string;
    array_add(*import_path, "modules");
    array_add(*import_path, ..opts.import_path);
    opts.import_path = import_path;
    set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name = executable_name;
    opts.output_path = build_dir;
    make_directory_if_it_does_not_exist(build_dir);
    set_build_options(opts, w);
    compiler_begin_intercept(w);
    add_build_file(test_file, w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .COMPLETE;
            mc := cast(*Message_Complete) message;
            if mc.error_code != .NONE {
                exit(1);
            }
            break;
        }
    }
    compiler_end_intercept(w);
    Autorun.run_build_result_of_workspace(w);
}

build_tests :: (options: Build_Options, build_dir: string = "build_tests") {
    build_and_run_test("tests", "tests", "modules/http_server/tests/test.jai", build_dir);
    build_and_run_test("datetime_tests", "datetime_tests", "modules/datetime/tests/test.jai", build_dir);
    build_and_run_test("channel_tests", "channel_tests", "modules/channel/tests/test.jai", build_dir);
    build_and_run_test("csv_tests", "csv_tests", "modules/csv/tests/test.jai", build_dir);
    set_build_options_dc(.{do_output=false});
}


build :: () {
    set_working_directory(#filepath);
    options := get_build_options();
    args := options.compile_time_command_line;
    for arg: args {
        if arg == {
          case "release";
            build_sample_programs(options, "release", "build_release");
          case "debug";
            build_sample_programs(options);
          case "test";
            build_tests(options);
          case;
            compiler_report(tprint("Command-line argument #%, '%', is invalid. Valid options are: 'debug', 'release', 'test'.\n", it_index+1, arg));
        }
    }
}

#import "Basic";
#import "Compiler";
#import "File";
Autorun :: #import "Autorun";
