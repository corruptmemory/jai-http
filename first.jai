
#run,stallable build();

build :: () {
    set_working_directory(#filepath);
    build := "debug";
    build_dir := "build_debug";
    options := get_build_options();
    args := options.compile_time_command_line;
    for arg: args {
        if arg == {
          case "release";
            build := "release";
            build_dir = "build_release";
          case "debug";
          case;
            compiler_report(tprint("Command-line argument #%, '%', is invalid. Valid options are: 'debug', 'release'.\n", it_index+1, arg));
        }
    }

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

#import "Basic";
#import "Compiler";
#import "File";
