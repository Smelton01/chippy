const std = @import("std");

const Backend = enum { raylib, terminal };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Which screen backend to compile in. The unselected backend file is never
    // analyzed (comptime @import switch in main.zig), so a terminal build pulls
    // in no raylib at all.
    const backend = b.option(Backend, "backend", "screen backend: raylib (default) or terminal") orelse .raylib;

    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("build_options", options.createModule());

    // raylib is only needed for the raylib backend; the terminal backend needs
    // libc for the termios/read/write/nanosleep syscalls.
    switch (backend) {
        .raylib => {
            const raylib_dep = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
            exe_mod.addImport("raylib", raylib_dep.module("raylib"));
            exe_mod.linkLibrary(raylib_dep.artifact("raylib"));
        },
        .terminal => exe_mod.link_libc = true,
    }

    const exe = b.addExecutable(.{ .name = "chippy", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);

    // Core unit tests run against chip8.zig in isolation — no backend, no window.
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/chip8.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run VM core unit tests");
    test_step.dependOn(&run_core_tests.step);
}
