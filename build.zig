const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // raylib-zig: built from source by `zig build`, no system install needed.
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // the bindings
    const raylib_artifact = raylib_dep.artifact("raylib"); // the C library

    // The application executable. main.zig is thin glue; chip8.zig / platform.zig
    // are imported as files within this same root module.
    const exe = b.addExecutable(.{
        .name = "chippy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib },
            },
        }),
    });
    exe.root_module.linkLibrary(raylib_artifact);
    b.installArtifact(exe);

    // `zig build run -- <rom> [scale] [cycles]`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);

    // Core unit tests run against chip8.zig in isolation — no raylib, no window.
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
