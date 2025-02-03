const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    const exe = b.addExecutable(.{
        .name = "glizp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const logz = b.dependency("logz", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("logz", logz.module("logz"));

    const regex = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("regex", regex.module("regex"));

    // Provides glizp module out, which makes glizp to be used as a library.
    const glizp_module = b.addModule("glizp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    glizp_module.addImport("logz", logz.module("logz"));
    glizp_module.addImport("regex", regex.module("regex"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const fs_tests = b.addTest(.{
        .root_source_file = b.path("tests/testing_fs.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = b.path("test_runner.zig"),
    });

    fs_tests.root_module.addImport("glizp", glizp_module);

    const run_fs_tests = b.addRunArtifact(fs_tests);

    // Creates a step for general testing. This only builds the test executable
    // but does not run it.
    const general_tests = b.addTest(.{
        .root_source_file = b.path("tests/testing_lisp_general.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = b.path("test_runner.zig"),
    });

    general_tests.root_module.addImport("glizp", glizp_module);
    general_tests.root_module.addImport("logz", logz.module("logz"));
    general_tests.root_module.addImport("regex", regex.module("regex"));

    const run_general_tests = b.addRunArtifact(general_tests);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = b.path("test_runner.zig"),
    });

    exe_unit_tests.root_module.addImport("logz", logz.module("logz"));
    exe_unit_tests.root_module.addImport("regex", regex.module("regex"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const reader_test = b.addTest(.{
        .root_source_file = b.path("./src/reader.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = b.path("test_runner.zig"),
    });
    reader_test.root_module.addImport("logz", logz.module("logz"));
    reader_test.root_module.addImport("regex", regex.module("regex"));

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_fs_tests.step);
    test_step.dependOn(&run_general_tests.step);
    test_step.dependOn(&reader_test.step);
}
