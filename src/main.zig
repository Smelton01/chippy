const std = @import("std");
const rl = @import("raylib");

pub fn main() !void {
    const scale = 10;
    const width = 64 * scale;
    const height = 32 * scale;

    rl.initWindow(width, height, "chippy — CHIP-8");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
    }
}
