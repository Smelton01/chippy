//! raylib I/O layer: window, scaled framebuffer rendering, keypad input, and a
//! square-wave beep. The VM core knows nothing about this file — `main.zig`
//! bridges the two. Swapping renderers means rewriting only this module.
//!
//! API verified against the raylib-zig v6.0.0 binding (functions camelCase,
//! types PascalCase, enum members snake_case).

const std = @import("std");
const rl = @import("raylib");
const chip8 = @import("chip8.zig");

pub const Platform = struct {
    scale: i32,
    beep: rl.Sound,

    /// CHIP-8 keypad index -> physical key (standard layout):
    ///   1 2 3 C        1 2 3 4
    ///   4 5 6 D   <-   Q W E R
    ///   7 8 9 E        A S D F
    ///   A 0 B F        Z X C V
    const keymap = [16]rl.KeyboardKey{
        .x,    // 0x0
        .one,  // 0x1
        .two,  // 0x2
        .three, // 0x3
        .q,    // 0x4
        .w,    // 0x5
        .e,    // 0x6
        .a,    // 0x7
        .s,    // 0x8
        .d,    // 0x9
        .z,    // 0xA
        .c,    // 0xB
        .four, // 0xC
        .r,    // 0xD
        .f,    // 0xE
        .v,    // 0xF
    };

    const fg = rl.Color.white; // lit pixel
    const bg = rl.Color.black; // background

    pub fn init(scale: i32) Platform {
        rl.initWindow(chip8.video_width * scale, chip8.video_height * scale, "chippy — CHIP-8");
        rl.setTargetFPS(60); // locks the main loop, timers, and rendering to 60 Hz
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
        return rl.windowShouldClose(); // true on window close or ESC
    }

    /// Sample all 16 keys into the VM's keypad for this frame.
    pub fn pollKeys(_: *Platform, keypad: *[16]bool) void {
        for (keymap, 0..) |key, i| keypad[i] = rl.isKeyDown(key);
    }

    /// Draw the 64x32 framebuffer scaled up: one filled rect per lit pixel.
    pub fn render(self: *Platform, video: []const bool) void {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(bg);
        for (video, 0..) |on, idx| {
            if (!on) continue;
            const x: i32 = @intCast(idx % chip8.video_width);
            const y: i32 = @intCast(idx / chip8.video_width);
            rl.drawRectangle(x * self.scale, y * self.scale, self.scale, self.scale, fg);
        }
    }

    /// Play the beep while the sound timer is non-zero. playSound doesn't loop,
    /// so re-trigger whenever it finishes but the timer is still set.
    pub fn updateSound(self: *Platform, sound_timer: u8) void {
        if (sound_timer > 0) {
            if (!rl.isSoundPlaying(self.beep)) rl.playSound(self.beep);
        } else if (rl.isSoundPlaying(self.beep)) {
            rl.stopSound(self.beep);
        }
    }

    /// Synthesize a 0.25 s, 440 Hz square wave (the classic CHIP-8 beep).
    /// loadSoundFromWave copies the samples, so the local buffer can die after.
    fn buildBeep() rl.Sound {
        const sample_rate: u32 = 44100;
        const tone_hz: f32 = 440.0;
        const len: usize = 11025; // 0.25 s
        var samples: [len]i16 = undefined;
        for (&samples, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
            const square: f32 = if (@sin(2.0 * std.math.pi * tone_hz * t) >= 0.0) 1.0 else -1.0;
            s.* = @intFromFloat(square * 6000.0); // amplitude well under i16 max
        }
        const wave = rl.Wave{
            .frameCount = @intCast(len),
            .sampleRate = @intCast(sample_rate),
            .sampleSize = 16, // bits per sample (matches i16)
            .channels = 1, // mono
            .data = @ptrCast(&samples),
        };
        return rl.loadSoundFromWave(wave);
    }
};
