//! raylib I/O layer: window lifecycle, framebuffer rendering, keypad input, and
//! a square-wave beep. The VM core knows nothing about this file. UI overlays
//! (menu, debug HUD) are drawn by app.zig between beginFrame()/endFrame() using
//! the layout constants exported here.
//!
//! Window layout:
//!   [ 0 .. game_h )            64x32 game framebuffer, scaled
//!   [ game_h .. window_h )     info panel (status / menu list / register dump)

const std = @import("std");
const rl = @import("raylib");
const chip8 = @import("chip8.zig");

/// Height in pixels of the bottom info panel (menu list / debug registers).
pub const panel_h: i32 = 210;

pub const Platform = struct {
    scale: i32,
    beep: rl.Sound,

    const keymap = [16]rl.KeyboardKey{
        .x, .one, .two, .three, // 0 1 2 3
        .q, .w, .e, .a, // 4 5 6 7
        .s, .d, .z, .c, // 8 9 A B
        .four, .r, .f, .v, // C D E F
    };

    pub fn init(scale: i32) Platform {
        rl.initWindow(64 * scale, 32 * scale + panel_h, "chippy — CHIP-8");
        rl.setTargetFPS(60);
        rl.setExitKey(.null); // we handle Esc ourselves (menu = quit, in-game = back)
        rl.initAudioDevice();
        const beep = buildBeep();
        rl.setSoundVolume(beep, 0.4);
        return .{ .scale = scale, .beep = beep };
    }

    pub fn deinit(self: *Platform) void {
        rl.unloadSound(self.beep);
        rl.closeAudioDevice();
        rl.closeWindow();
    }

    pub fn shouldClose(_: *Platform) bool {
        return rl.windowShouldClose();
    }

    pub fn gameHeight(self: *Platform) i32 {
        return 32 * self.scale;
    }
    pub fn windowWidth(self: *Platform) i32 {
        return 64 * self.scale;
    }

    /// Sample all 16 keys into the VM's keypad for this frame.
    pub fn pollKeys(_: *Platform, keypad: *[16]bool) void {
        for (keymap, 0..) |key, i| keypad[i] = rl.isKeyDown(key);
    }

    pub fn beginFrame(_: *Platform) void {
        rl.beginDrawing();
        rl.clearBackground(.black);
    }
    pub fn endFrame(_: *Platform) void {
        rl.endDrawing();
    }

    /// Draw the 64x32 framebuffer filling the game area at the window scale.
    pub fn drawVideo(self: *Platform, video: []const bool) void {
        self.drawVideoRegion(video, 0, 0, self.scale, .white);
    }

    /// Draw a 64x32 framebuffer at an arbitrary origin/scale (used for the menu
    /// welcome banner and the game area).
    pub fn drawVideoRegion(_: *Platform, video: []const bool, ox: i32, oy: i32, s: i32, color: rl.Color) void {
        for (video, 0..) |on, idx| {
            if (!on) continue;
            const x: i32 = @intCast(idx % chip8.video_width);
            const y: i32 = @intCast(idx / chip8.video_width);
            rl.drawRectangle(ox + x * s, oy + y * s, s, s, color);
        }
    }

    /// Play the beep while the sound timer is non-zero (playSound doesn't loop).
    pub fn updateSound(self: *Platform, sound_timer: u8) void {
        if (sound_timer > 0) {
            if (!rl.isSoundPlaying(self.beep)) rl.playSound(self.beep);
        } else if (rl.isSoundPlaying(self.beep)) {
            rl.stopSound(self.beep);
        }
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
