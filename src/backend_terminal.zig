//! Terminal backend: renders the 64x32 display as half-block characters and the
//! info panel as colored text, with raw-mode keyboard input. No raylib — only
//! libc syscalls (termios/read/write/nanosleep), so a `-Dbackend=terminal` build
//! links no GUI/audio at all.
//!
//! Terminal input has no key-up event, so the 16-key game keypad uses *key-hold
//! decay*: a keystroke marks a key "down" for `hold_frames`; terminal auto-repeat
//! keeps it alive while held, and it decays once you let go. Imperfect but
//! playable.
//!
//! Controls: arrows move / right=step, Enter select, Space pause/step-resume,
//! Tab registers, Backspace menu, Esc quit (menu), Ctrl-C quit anywhere. Game
//! keypad mirrors the desktop layout (1234/QWER/ASDF/ZXCV).

const std = @import("std");
const posix = std.posix;
const chip8 = @import("chip8.zig");
const iface = @import("backend.zig");
const Action = iface.Action;
const Style = iface.Style;

const hold_frames: u8 = 8; // ~130ms a key stays "down" after the last keystroke
const nontty_frames: u64 = 90; // when stdin is piped: render this many frames, then stop

// Saved terminal state for the SIGINT handler (which can't take arguments).
var g_saved: ?posix.termios = null;

pub const Backend = struct {
    raw: bool = false,
    orig: posix.termios = undefined,
    keys: [16]u8 = [_]u8{0} ** 16, // per-keypad-key TTL in frames
    acts: [16]bool = [_]bool{false} ** 16, // actions seen this frame (indexed by @intFromEnum)
    close: bool = false, // Ctrl-C
    beeping: bool = false,
    frames: u64 = 0,
    obuf: [48 * 1024]u8 = undefined, // one write per frame (no flicker)
    olen: usize = 0,

    pub fn init(gpa: std.mem.Allocator, scale: i32) !Backend {
        _ = gpa;
        _ = scale; // size is fixed by the 64x32 display
        var self = Backend{};
        if (posix.tcgetattr(posix.STDIN_FILENO)) |orig| {
            self.orig = orig;
            self.raw = true;
            var raw = orig;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false; // deliver Ctrl-C as byte 0x03 instead of a signal
            raw.cc[@intFromEnum(posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(posix.V.TIME)] = 0;
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {};
            g_saved = orig;
            installSigint();
            writeRaw("\x1b[?25l\x1b[2J"); // hide cursor, clear screen
        } else |_| {
            self.raw = false; // not a tty (piped): render-only, auto-exit
        }
        return self;
    }

    pub fn deinit(self: *Backend) void {
        if (!self.raw) return;
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
        writeRaw("\x1b[?25h\x1b[0m\n"); // show cursor, reset attributes
        g_saved = null;
    }

    pub fn shouldClose(self: *Backend) bool {
        return if (self.raw) self.close else self.frames >= nontty_frames;
    }

    pub fn beginFrame(self: *Backend) void {
        self.pollInput();
        self.olen = 0;
        if (self.raw) self.put("\x1b[H"); // cursor home: redraw in place
    }

    pub fn endFrame(self: *Backend) void {
        if (self.raw) self.put("\x1b[J"); // clear anything below (stale lines)
        writeRaw(self.obuf[0..self.olen]);
        self.frames += 1;
        for (&self.keys) |*k| k.* -|= 1; // decay held keys
        var req = posix.timespec{ .sec = 0, .nsec = 16 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&req, &req); // ~60 Hz
    }

    /// Render 64x32 as 16 rows of half-block glyphs (two pixel rows per line).
    pub fn drawDisplay(self: *Backend, video: []const bool) void {
        const w = chip8.video_width;
        var ty: usize = 0;
        while (ty < chip8.video_height / 2) : (ty += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const top = video[(ty * 2) * w + x];
                const bot = video[(ty * 2 + 1) * w + x];
                self.put(if (top and bot) "\u{2588}" else if (top) "\u{2580}" else if (bot) "\u{2584}" else " ");
            }
            self.put(self.eol());
        }
    }

    pub fn panelRows(_: *Backend) usize {
        return 16;
    }

    pub fn panelLine(self: *Backend, row: usize, style: Style, text: [:0]const u8) void {
        _ = row; // lines are emitted in order; print sequentially below the display
        self.put(self.sgr(style));
        self.put(text);
        if (self.raw) self.put("\x1b[0m");
        self.put(self.eol());
    }

    pub fn actionPressed(self: *Backend, action: Action) bool {
        return self.acts[@intFromEnum(action)];
    }

    pub fn pollEmuKeys(self: *Backend, keypad: *[16]bool) void {
        for (keypad, 0..) |*k, i| k.* = self.keys[i] > 0;
    }

    pub fn setBeep(self: *Backend, on: bool) void {
        if (on and !self.beeping) writeRaw("\x07"); // bell on rising edge
        self.beeping = on;
    }
    // (no screenshot method — app.zig guards the call with @hasDecl)

    // ---- input ------------------------------------------------------------

    fn pollInput(self: *Backend) void {
        @memset(&self.acts, false);
        if (!self.raw) return;
        var buf: [64]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &buf) catch 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = buf[i];
            if (c == 0x1b) { // escape: arrow sequence ESC [ A/B/C/D, else lone Esc
                if (i + 2 < n and buf[i + 1] == '[') {
                    switch (buf[i + 2]) {
                        'A' => self.setAct(.up),
                        'B' => self.setAct(.down),
                        'C' => self.setAct(.step), // right arrow = step
                        else => {},
                    }
                    i += 2;
                } else {
                    self.setAct(.quit); // lone Esc quits (menu)
                }
                continue;
            }
            switch (c) {
                0x03 => self.close = true, // Ctrl-C
                '\r', '\n' => self.setAct(.select),
                ' ' => self.setAct(.pause_resume),
                '\t' => self.setAct(.toggle_regs),
                0x7f, 0x08 => self.setAct(.back),
                'n', 'N' => self.setAct(.step),
                'r', 'R' => self.setAct(.random),
                // vim bindings: k/j up/down, l step, h back
                'k' => self.setAct(.up),
                'j' => self.setAct(.down),
                'l' => self.setAct(.step),
                'h' => self.setAct(.back),
                else => {},
            }
            if (keypadIndex(c)) |idx| self.keys[idx] = hold_frames;
        }
    }

    fn setAct(self: *Backend, a: Action) void {
        self.acts[@intFromEnum(a)] = true;
    }

    // ---- output buffer helpers --------------------------------------------

    fn put(self: *Backend, bytes: []const u8) void {
        const end = @min(self.olen + bytes.len, self.obuf.len);
        const n = end - self.olen;
        @memcpy(self.obuf[self.olen..end], bytes[0..n]);
        self.olen = end;
    }

    fn eol(self: *Backend) []const u8 {
        return if (self.raw) "\x1b[K\r\n" else "\n";
    }

    fn sgr(self: *Backend, style: Style) []const u8 {
        if (!self.raw) return "";
        return switch (style) {
            .normal => "\x1b[0m",
            .dim => "\x1b[2m",
            .accent => "\x1b[32m",
            .highlight => "\x1b[1;33m",
            .err => "\x1b[31m",
        };
    }
};

/// Map a typed character to a CHIP-8 keypad index (1234/QWER/ASDF/ZXCV layout).
fn keypadIndex(c: u8) ?u4 {
    return switch (c) {
        '1' => 0x1, '2' => 0x2, '3' => 0x3, '4' => 0xC,
        'q', 'Q' => 0x4, 'w', 'W' => 0x5, 'e', 'E' => 0x6, 'r', 'R' => 0xD,
        'a', 'A' => 0x7, 's', 'S' => 0x8, 'd', 'D' => 0x9, 'f', 'F' => 0xE,
        'z', 'Z' => 0xA, 'x', 'X' => 0x0, 'c', 'C' => 0xB, 'v', 'V' => 0xF,
        else => null,
    };
}

fn writeRaw(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(posix.STDOUT_FILENO, bytes.ptr + off, bytes.len - off);
        if (rc <= 0) return;
        off += @intCast(rc);
    }
}

fn onSigint(_: posix.SIG) callconv(.c) void {
    if (g_saved) |t| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, t) catch {};
    writeRaw("\x1b[?25h\x1b[0m\n"); // restore cursor before dying
    std.c.exit(130);
}

fn installSigint() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
}
