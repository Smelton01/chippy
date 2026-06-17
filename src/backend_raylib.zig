//! raylib backend: window, scaled framebuffer + bottom info panel, keypad/audio.
//! Implements the interface in backend.zig. Owns all raylib-specific concerns —
//! pixel layout, Style→Color, Action→KeyboardKey — so app.zig stays generic.

const std = @import("std");
const rl = @import("raylib");
const chip8 = @import("chip8.zig");
const iface = @import("backend.zig");
const Action = iface.Action;
const Style = iface.Style;

pub const Backend = struct {
    scale: i32,
    beep: rl.Sound,

    /// Bottom info-panel geometry.
    const panel_h: i32 = 210;
    const line_h: i32 = 22;
    const text_size: i32 = 16;

    /// CHIP-8 keypad index -> physical key (standard 1234/QWER/ASDF/ZXCV layout).
    const keymap = [16]rl.KeyboardKey{
        .x, .one, .two, .three, // 0 1 2 3
        .q, .w, .e, .a, // 4 5 6 7
        .s, .d, .z, .c, // 8 9 A B
        .four, .r, .f, .v, // C D E F
    };

    pub fn init(gpa: std.mem.Allocator, scale: i32) !Backend {
        _ = gpa;
        rl.initWindow(64 * scale, 32 * scale + panel_h, "chippy — CHIP-8");
        rl.setTargetFPS(60);
        rl.setExitKey(.null); // app handles Esc (menu = quit, in-game = back)
        rl.initAudioDevice();
        const beep = buildBeep();
        rl.setSoundVolume(beep, 0.4);
        return .{ .scale = scale, .beep = beep };
    }

    pub fn deinit(self: *Backend) void {
        rl.unloadSound(self.beep);
        rl.closeAudioDevice();
        rl.closeWindow();
    }

    pub fn shouldClose(_: *Backend) bool {
        return rl.windowShouldClose();
    }

    pub fn beginFrame(self: *Backend) void {
        rl.beginDrawing();
        rl.clearBackground(.black);
        rl.drawRectangle(0, 32 * self.scale, 64 * self.scale, 2, rl.Color.dark_gray); // panel divider
    }

    pub fn endFrame(_: *Backend) void {
        rl.endDrawing();
    }

    pub fn drawDisplay(self: *Backend, video: []const bool) void {
        for (video, 0..) |on, idx| {
            if (!on) continue;
            const x: i32 = @intCast(idx % chip8.video_width);
            const y: i32 = @intCast(idx / chip8.video_width);
            rl.drawRectangle(x * self.scale, y * self.scale, self.scale, self.scale, rl.Color.white);
        }
    }

    pub fn panelRows(_: *Backend) usize {
        return @intCast(@max(@divTrunc(panel_h - 12, line_h), 1));
    }

    pub fn panelLine(self: *Backend, row: usize, style: Style, text: [:0]const u8) void {
        const y = 32 * self.scale + 6 + @as(i32, @intCast(row)) * line_h;
        rl.drawText(text, 12, y, text_size, colorOf(style));
    }

    fn colorOf(style: Style) rl.Color {
        return switch (style) {
            .normal => .white,
            .dim => .gray,
            .accent => .green,
            .highlight => .yellow,
            .err => .red,
        };
    }

    pub fn actionPressed(_: *Backend, action: Action) bool {
        return switch (action) {
            .up => rl.isKeyPressed(.up),
            .down => rl.isKeyPressed(.down),
            .select => rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter),
            .random => rl.isKeyPressed(.r),
            .quit => rl.isKeyPressed(.escape),
            .pause_resume => rl.isKeyPressed(.space),
            .step => rl.isKeyPressed(.n) or rl.isKeyPressed(.right),
            .toggle_regs => rl.isKeyPressed(.tab),
            .back => rl.isKeyPressed(.backspace),
        };
    }

    pub fn pollEmuKeys(_: *Backend, keypad: *[16]bool) void {
        for (keymap, 0..) |key, i| keypad[i] = rl.isKeyDown(key);
    }

    pub fn setBeep(self: *Backend, on: bool) void {
        if (on) {
            if (!rl.isSoundPlaying(self.beep)) rl.playSound(self.beep);
        } else if (rl.isSoundPlaying(self.beep)) {
            rl.stopSound(self.beep);
        }
    }

    pub fn screenshot(_: *Backend, path: [:0]const u8) void {
        rl.takeScreenshot(path);
    }

    /// Synthesize a 0.25 s, 440 Hz square wave (the classic CHIP-8 beep).
    fn buildBeep() rl.Sound {
        const sample_rate: u32 = 44100;
        const tone_hz: f32 = 440.0;
        const len: usize = 11025; // 0.25 s
        var samples: [len]i16 = undefined;
        for (&samples, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
            const square: f32 = if (@sin(2.0 * std.math.pi * tone_hz * t) >= 0.0) 1.0 else -1.0;
            s.* = @intFromFloat(square * 6000.0);
        }
        const wave = rl.Wave{
            .frameCount = @intCast(len),
            .sampleRate = @intCast(sample_rate),
            .sampleSize = 16,
            .channels = 1,
            .data = @ptrCast(&samples),
        };
        return rl.loadSoundFromWave(wave);
    }
};
