//! Terminal backend — STUB. Implements the backend interface (backend.zig)
//! with no raylib dependency: it renders the 64x32 display as half-block
//! characters and prints the info panel as text lines.
//!
//! TODO (terminal, later): raw-mode stdin for real input (raylib's isKeyDown has
//! no terminal equivalent — needs termios + non-blocking reads + key-hold decay
//! so the 16-key game keypad is usable), cursor-home redraw instead of scroll,
//! and a proper quit key. For now input is inert and the loop auto-exits after a
//! fixed number of frames so `chippy <rom> -Dbackend=terminal | tail` shows the
//! rendered result.

const std = @import("std");
const chip8 = @import("chip8.zig");
const iface = @import("backend.zig");
const Action = iface.Action;
const Style = iface.Style;

pub const Backend = struct {
    frames: u64 = 0,
    beeping: bool = false,

    /// Stub auto-exit: render this many frames, then stop (until real input).
    const max_frames: u64 = 40;

    pub fn init(gpa: std.mem.Allocator, scale: i32) !Backend {
        _ = gpa;
        _ = scale; // terminal size is fixed by the display geometry
        return .{};
    }

    pub fn deinit(_: *Backend) void {}

    pub fn shouldClose(self: *Backend) bool {
        return self.frames >= max_frames; // TODO: read 'q'/Ctrl-C instead
    }

    pub fn beginFrame(_: *Backend) void {}

    pub fn endFrame(self: *Backend) void {
        self.frames += 1;
    }

    /// Render 64x32 as 16 rows of half-block glyphs (two pixel rows per line).
    pub fn drawDisplay(_: *Backend, video: []const bool) void {
        const w = chip8.video_width;
        var buf: [w * 3]u8 = undefined; // worst case: every cell is a 3-byte glyph
        var ty: usize = 0;
        while (ty < chip8.video_height / 2) : (ty += 1) {
            var len: usize = 0;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const top = video[(ty * 2) * w + x];
                const bot = video[(ty * 2 + 1) * w + x];
                const glyph: []const u8 = if (top and bot) "\u{2588}" else if (top) "\u{2580}" else if (bot) "\u{2584}" else " ";
                @memcpy(buf[len .. len + glyph.len], glyph);
                len += glyph.len;
            }
            std.debug.print("{s}\n", .{buf[0..len]});
        }
    }

    pub fn panelRows(_: *Backend) usize {
        return 12;
    }

    pub fn panelLine(_: *Backend, row: usize, style: Style, text: [:0]const u8) void {
        _ = row; // lines are emitted in order, so print sequentially
        _ = style;
        std.debug.print("{s}\n", .{text});
    }

    pub fn actionPressed(_: *Backend, action: Action) bool {
        _ = action;
        return false; // TODO: raw-mode stdin
    }

    pub fn pollEmuKeys(_: *Backend, keypad: *[16]bool) void {
        @memset(keypad, false); // TODO: raw-mode stdin with key-hold decay
    }

    pub fn setBeep(self: *Backend, on: bool) void {
        if (on and !self.beeping) std.debug.print("\x07", .{}); // terminal bell on rising edge
        self.beeping = on;
    }
    // (no screenshot method — app.zig guards the call with @hasDecl)
};
