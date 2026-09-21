const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("libnarnia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "libnarnia",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libnarnia", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // The C ABI surface. `src/c_api.zig` is a separate module rather than part
    // of `mod` so that the Zig library stays free of libc and of the `export`
    // symbols: consumers importing `libnarnia` from Zig don't pay for either.
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        // The bindings allocate through `std.heap.c_allocator`, and any C
        // consumer is linking libc anyway.
        .link_libc = true,
        .imports = &.{
            .{ .name = "libnarnia", .module = mod },
        },
    });

    // Both linkages are installed: the static one for the common case, the
    // shared one for consumers that need to dlopen or ship a .so/.dylib.
    // `narnia.h` is hand-written — don't rely on `-femit-h`.
    const static_lib = b.addLibrary(.{
        .name = "narnia",
        .linkage = .static,
        .root_module = c_api_mod,
    });
    static_lib.installHeadersDirectory(b.path("include"), "", .{});
    b.installArtifact(static_lib);

    const shared_lib = b.addLibrary(.{
        .name = "narnia",
        .linkage = .dynamic,
        .root_module = c_api_mod,
    });
    b.installArtifact(shared_lib);

    // The C example, linked against the static library the same way a
    // downstream C project would link it.
    const c_example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_example_mod.addCSourceFile(.{
        .file = b.path("examples/example.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    c_example_mod.addIncludePath(b.path("include"));
    c_example_mod.linkLibrary(static_lib);

    const c_example = b.addExecutable(.{
        .name = "narnia-example",
        .root_module = c_example_mod,
    });
    b.installArtifact(c_example);

    const c_example_step = b.step("example", "Run the C example");
    c_example_step.dependOn(&b.addRunArtifact(c_example).step);

    // The C API test suite
    const c_tests_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_tests_mod.addCSourceFile(.{
        .file = b.path("tests/test_c_api.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    c_tests_mod.addIncludePath(b.path("include"));
    c_tests_mod.linkLibrary(static_lib);

    const c_tests = b.addExecutable(.{
        .name = "narnia-c-tests",
        .root_module = c_tests_mod,
    });

    const c_tests_step = b.step("c-test", "Run the C API tests");
    c_tests_step.dependOn(&b.addRunArtifact(c_tests).step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // The bindings' own tests. `c_api.zig` imports the `libnarnia` module, so
    // it can't be run with a bare `zig test src/c_api.zig` — only the build
    // graph knows how to supply that import (and libc).
    const c_api_zig_tests = b.addTest(.{
        .root_module = c_api_mod,
    });

    const run_c_api_zig_tests = b.addRunArtifact(c_api_zig_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    // src/c_api.zig tests
    test_step.dependOn(&run_c_api_zig_tests.step);

    // libnarnia's docs
    const libnarnia_docs_step = b.step("docs", "Generate libnarnia docs");

    const libnarnia_docs_obj = b.addObject(.{
        .name = "libnarnia",
        .root_module = mod,
    });
    const install_libnarnia_docs = b.addInstallDirectory(.{
        .source_dir = libnarnia_docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    libnarnia_docs_step.dependOn(&install_libnarnia_docs.step);
}
