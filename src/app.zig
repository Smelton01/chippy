//! Application shell: a small state machine over the VM core, generic over a
//! rendering/input backend (see backend.zig). Three modes:
//!   .menu     — IBM-logo welcome + scrollable ROM picker (load / random / quit)
//!   .running  — normal emulation at 60 Hz
//!   .paused   — frozen; single-step the PC and inspect registers (debugger)
//!
//! The game (or, in the menu, the IBM banner) renders in the main display area;
//! a bottom info panel shows the ROM list / register dump / status as text
//! lines. The backend owns all pixel/character layout — this file only emits
//! display buffers, panel lines, and reads semantic actions.

const std = @import("std");
const chip8 = @import("chip8.zig");
const iface = @import("backend.zig");
const ibm = @import("ibm_logo.zig");
const Action = iface.Action;
const Style = iface.Style;

const Mode = enum { menu, running, paused };

/// `Backend` must satisfy the interface in backend.zig.
pub fn App(comptime Backend: type) type {
    comptime iface.verify(Backend);
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        backend: *Backend,
        rom_dir: []const u8,
        cycles_per_frame: u32,

        mode: Mode = .menu,
        vm: chip8.Chip8 = undefined,
        banner: chip8.Chip8 = undefined, // pre-rendered IBM logo for the welcome
        roms: std.ArrayList([:0]u8) = .empty, // owned, null-terminated filenames
        selected: usize = 0,
        scroll: usize = 0,
        hud: bool = false, // register overlay while running
        quit: bool = false,
        frame: u64 = 0,
        loaded_name: []const u8 = "",

        buf: [256]u8 = undefined, // scratch for text formatting
        msg: [128]u8 = undefined, // transient status/error message
        msg_len: usize = 0,
        msg_until: u64 = 0,

        pub fn init(gpa: std.mem.Allocator, io: std.Io, backend: *Backend, rom_dir: []const u8, cycles: u32) !Self {
            var app = Self{ .gpa = gpa, .io = io, .backend = backend, .rom_dir = rom_dir, .cycles_per_frame = cycles };
            // Pre-render the IBM logo into a framebuffer for the welcome banner.
            app.banner = chip8.Chip8.init(0);
            try app.banner.loadRom(&ibm.ibm_logo);
            var i: usize = 0;
            while (i < 30) : (i += 1) app.banner.cycle();
            try app.loadRomList();
            return app;
        }

        pub fn deinit(self: *Self) void {
            for (self.roms.items) |n| self.gpa.free(n);
            self.roms.deinit(self.gpa);
        }

        fn loadRomList(self: *Self) !void {
            var dir = std.Io.Dir.cwd().openDir(self.io, self.rom_dir, .{ .iterate = true }) catch |e| switch (e) {
                error.FileNotFound, error.NotDir => return, // empty list; menu shows a hint
                else => return e,
            };
            defer dir.close(self.io);
            var it = dir.iterate();
            while (try it.next(self.io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".ch8")) continue;
                const dup = try self.gpa.dupeZ(u8, entry.name);
                errdefer self.gpa.free(dup);
                try self.roms.append(self.gpa, dup);
            }
            std.mem.sort([:0]u8, self.roms.items, {}, lessThan);
        }

        fn lessThan(_: void, a: [:0]u8, b: [:0]u8) bool {
            return std.mem.lessThan(u8, a, b);
        }

        // ---- main loop --------------------------------------------------------

        pub fn run(self: *Self) void {
            while (!self.backend.shouldClose() and !self.quit) {
                self.frame +%= 1;
                self.step();
            }
        }

        /// One frame: handle input/update for the current mode, then render it.
        /// Split out from run() so a future wasm build can drive it from JS.
        pub fn step(self: *Self) void {
            switch (self.mode) {
                .menu => self.inputMenu(),
                .running => self.updateRunning(),
                .paused => self.inputPaused(),
            }
            self.renderMode();
        }

        fn renderMode(self: *Self) void {
            self.backend.beginFrame();
            defer self.backend.endFrame();
            switch (self.mode) {
                .menu => self.drawMenu(),
                .running => self.drawRunning(),
                .paused => self.drawPaused(),
            }
        }

        // ---- menu -------------------------------------------------------------

        fn inputMenu(self: *Self) void {
            const n = self.roms.items.len;
            if (n > 0) {
                if (self.backend.actionPressed(.down)) self.selected = (self.selected + 1) % n;
                if (self.backend.actionPressed(.up)) self.selected = (self.selected + n - 1) % n;
                if (self.backend.actionPressed(.select)) _ = self.loadIndex(self.selected);
                if (self.backend.actionPressed(.random)) {
                    var prng = std.Random.DefaultPrng.init(self.frame);
                    _ = self.loadIndex(prng.random().uintLessThan(usize, n));
                }
            }
            if (self.backend.actionPressed(.quit)) self.quit = true;
        }

        fn drawMenu(self: *Self) void {
            self.backend.drawDisplay(&self.banner.video);
            self.line(0, .dim, "select a ROM   j/k move   enter load   R random   esc quit", .{});

            if (self.roms.items.len == 0) {
                self.line(2, .err, "No ROMs in ./{s} — add .ch8 files (see README).", .{self.rom_dir});
                return;
            }

            const visible = self.backend.panelRows() -| 1; // row 0 is the hint
            self.clampScroll(visible);
            var row: usize = 0;
            while (row < visible and self.scroll + row < self.roms.items.len) : (row += 1) {
                const idx = self.scroll + row;
                const style: Style = if (idx == self.selected) .highlight else .normal;
                const marker = if (idx == self.selected) ">" else " ";
                self.line(row + 1, style, "{s} {s}", .{ marker, self.roms.items[idx] });
            }
            if (self.frame < self.msg_until) {
                self.line(self.backend.panelRows() -| 1, .err, "{s}", .{self.msg[0..self.msg_len]});
            }
        }

        fn clampScroll(self: *Self, visible: usize) void {
            if (visible == 0) return;
            if (self.selected < self.scroll) self.scroll = self.selected;
            if (self.selected >= self.scroll + visible) self.scroll = self.selected - visible + 1;
        }

        /// Returns true on success (VM initialized and mode set to .running).
        fn loadIndex(self: *Self, idx: usize) bool {
            const name = self.roms.items[idx];
            var pathbuf: [1024]u8 = undefined;
            const path = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ self.rom_dir, name }) catch return false;
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 * 1024)) catch |e| {
                self.flash("cannot load {s}: {s}", .{ name, @errorName(e) });
                return false;
            };
            defer self.gpa.free(bytes);
            self.vm = chip8.Chip8.init(std.hash.Wyhash.hash(self.frame, bytes));
            self.vm.loadRom(bytes) catch {
                self.flash("{s} too large ({d} bytes)", .{ name, bytes.len });
                return false;
            };
            self.loaded_name = name;
            self.selected = idx;
            self.hud = false;
            self.mode = .running;
            return true;
        }

        /// Load a ROM directly by path (the optional CLI argument), bypassing the
        /// menu. On failure, flashes a message and stays in the menu.
        pub fn loadPath(self: *Self, path: []const u8) void {
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 * 1024)) catch |e| {
                self.flash("cannot load {s}: {s}", .{ path, @errorName(e) });
                return;
            };
            defer self.gpa.free(bytes);
            self.vm = chip8.Chip8.init(std.hash.Wyhash.hash(self.frame, bytes));
            self.vm.loadRom(bytes) catch {
                self.flash("{s} too large ({d} bytes)", .{ path, bytes.len });
                return;
            };
            self.loaded_name = std.fs.path.basename(path);
            self.hud = false;
            self.mode = .running;
        }

        // ---- running ----------------------------------------------------------

        fn updateRunning(self: *Self) void {
            self.backend.pollEmuKeys(&self.vm.keypad);
            if (self.backend.actionPressed(.back)) {
                self.mode = .menu;
                self.backend.setBeep(false);
                return;
            }
            if (self.backend.actionPressed(.pause_resume)) {
                self.mode = .paused;
                self.backend.setBeep(false);
                return;
            }
            if (self.backend.actionPressed(.toggle_regs)) self.hud = !self.hud;

            var i: u32 = 0;
            while (i < self.cycles_per_frame) : (i += 1) self.vm.cycle();
            self.vm.decrementTimers();
            self.backend.setBeep(self.vm.sound_timer > 0);
        }

        fn drawRunning(self: *Self) void {
            self.backend.drawDisplay(&self.vm.video);
            if (self.hud) {
                self.drawRegisters();
            } else {
                self.line(0, .accent, "> {s}   {d}/frame", .{ self.loaded_name, self.cycles_per_frame });
                self.line(1, .dim, "SPACE pause/debug   TAB registers   BACKSPACE menu", .{});
            }
        }

        // ---- paused / debugger ------------------------------------------------

        fn inputPaused(self: *Self) void {
            if (self.backend.actionPressed(.back)) {
                self.mode = .menu;
                return;
            }
            if (self.backend.actionPressed(.pause_resume)) {
                self.mode = .running;
                return;
            }
            if (self.backend.actionPressed(.step)) {
                self.backend.pollEmuKeys(&self.vm.keypad); // let held keys affect the stepped instr
                self.vm.cycle(); // single instruction; timers are not ticked while stepping
            }
        }

        fn drawPaused(self: *Self) void {
            self.backend.drawDisplay(&self.vm.video);
            self.drawRegisters();
        }

        fn drawRegisters(self: *Self) void {
            const op = self.peekOpcode();
            var dbuf: [32]u8 = undefined;
            const head = if (self.mode == .paused) "[PAUSED]" else "[run]";
            self.line(0, .highlight, "{s} {s}   PC 0x{X:0>3}  OP 0x{X:0>4}  {s}", .{ head, self.loaded_name, self.vm.pc, op, describe(op, &dbuf) });
            self.line(1, .normal, "I 0x{X:0>3}   SP {d}   DT {d}   ST {d}", .{ self.vm.index, self.vm.sp, self.vm.delay_timer, self.vm.sound_timer });
            self.line(2, .normal, "V0 {X:0>2} V1 {X:0>2} V2 {X:0>2} V3 {X:0>2} V4 {X:0>2} V5 {X:0>2} V6 {X:0>2} V7 {X:0>2}", .{
                self.vm.v[0], self.vm.v[1], self.vm.v[2], self.vm.v[3], self.vm.v[4], self.vm.v[5], self.vm.v[6], self.vm.v[7],
            });
            self.line(3, .normal, "V8 {X:0>2} V9 {X:0>2} VA {X:0>2} VB {X:0>2} VC {X:0>2} VD {X:0>2} VE {X:0>2} VF {X:0>2}", .{
                self.vm.v[8], self.vm.v[9], self.vm.v[10], self.vm.v[11], self.vm.v[12], self.vm.v[13], self.vm.v[14], self.vm.v[15],
            });
            self.line(4, .dim, "n/l step      SPACE {s}      h/BACKSPACE menu", .{if (self.mode == .paused) "resume" else "pause"});
        }

        fn peekOpcode(self: *Self) u16 {
            const h: u16 = self.vm.memory[self.vm.pc & 0x0FFF];
            const l: u16 = self.vm.memory[(self.vm.pc +% 1) & 0x0FFF];
            return (h << 8) | l;
        }

        // ---- screenshot capture (verification; raylib only) -------------------

        pub fn capture(self: *Self, prefix: []const u8) void {
            self.snap(prefix, "menu");
            if (self.roms.items.len > 0 and self.loadIndex(0)) {
                var f: usize = 0;
                while (f < 60) : (f += 1) {
                    var k: u32 = 0;
                    while (k < self.cycles_per_frame) : (k += 1) self.vm.cycle();
                    self.vm.decrementTimers();
                }
                self.hud = true;
                self.snap(prefix, "running");
                self.mode = .paused;
                self.snap(prefix, "debug");
            }
        }

        fn snap(self: *Self, prefix: []const u8, tag: []const u8) void {
            self.renderMode();
            self.renderMode(); // render twice: takeScreenshot reads the prior (swapped) buffer
            if (@hasDecl(Backend, "screenshot")) {
                var nbuf: [256]u8 = undefined;
                const name = std.fmt.bufPrintZ(&nbuf, "{s}-{s}.png", .{ prefix, tag }) catch return;
                self.backend.screenshot(name);
            }
        }

        // ---- text helpers -----------------------------------------------------

        fn line(self: *Self, row: usize, style: Style, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrintZ(&self.buf, fmt, args) catch return;
            self.backend.panelLine(row, style, s);
        }

        fn flash(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(&self.msg, fmt, args) catch return;
            self.msg_len = s.len;
            self.msg_until = self.frame + 180; // ~3 seconds
        }
    };
}

/// One-line disassembly of an opcode for the debugger.
fn describe(op: u16, buf: []u8) []const u8 {
    const x = (op >> 8) & 0xF;
    const y = (op >> 4) & 0xF;
    const n = op & 0xF;
    const nn = op & 0xFF;
    const nnn = op & 0xFFF;
    const f = std.fmt.bufPrint;
    return switch (op >> 12) {
        0x0 => switch (nn) {
            0xE0 => "CLS",
            0xEE => "RET",
            else => "SYS",
        },
        0x1 => f(buf, "JP {X:0>3}", .{nnn}) catch "JP",
        0x2 => f(buf, "CALL {X:0>3}", .{nnn}) catch "CALL",
        0x3 => f(buf, "SE V{X} {X:0>2}", .{ x, nn }) catch "SE",
        0x4 => f(buf, "SNE V{X} {X:0>2}", .{ x, nn }) catch "SNE",
        0x5 => f(buf, "SE V{X} V{X}", .{ x, y }) catch "SE",
        0x6 => f(buf, "LD V{X} {X:0>2}", .{ x, nn }) catch "LD",
        0x7 => f(buf, "ADD V{X} {X:0>2}", .{ x, nn }) catch "ADD",
        0x8 => switch (n) {
            0x0 => f(buf, "LD V{X} V{X}", .{ x, y }) catch "LD",
            0x1 => f(buf, "OR V{X} V{X}", .{ x, y }) catch "OR",
            0x2 => f(buf, "AND V{X} V{X}", .{ x, y }) catch "AND",
            0x3 => f(buf, "XOR V{X} V{X}", .{ x, y }) catch "XOR",
            0x4 => f(buf, "ADD V{X} V{X}", .{ x, y }) catch "ADD",
            0x5 => f(buf, "SUB V{X} V{X}", .{ x, y }) catch "SUB",
            0x6 => f(buf, "SHR V{X}", .{x}) catch "SHR",
            0x7 => f(buf, "SUBN V{X} V{X}", .{ x, y }) catch "SUBN",
            0xE => f(buf, "SHL V{X}", .{x}) catch "SHL",
            else => "8?",
        },
        0x9 => f(buf, "SNE V{X} V{X}", .{ x, y }) catch "SNE",
        0xA => f(buf, "LD I {X:0>3}", .{nnn}) catch "LD I",
        0xB => f(buf, "JP V0 {X:0>3}", .{nnn}) catch "JP V0",
        0xC => f(buf, "RND V{X} {X:0>2}", .{ x, nn }) catch "RND",
        0xD => f(buf, "DRW V{X} V{X} {X}", .{ x, y, n }) catch "DRW",
        0xE => switch (nn) {
            0x9E => f(buf, "SKP V{X}", .{x}) catch "SKP",
            0xA1 => f(buf, "SKNP V{X}", .{x}) catch "SKNP",
            else => "E?",
        },
        0xF => switch (nn) {
            0x07 => f(buf, "LD V{X} DT", .{x}) catch "LD DT",
            0x0A => f(buf, "LD V{X} KEY", .{x}) catch "LD KEY",
            0x15 => f(buf, "LD DT V{X}", .{x}) catch "LD DT",
            0x18 => f(buf, "LD ST V{X}", .{x}) catch "LD ST",
            0x1E => f(buf, "ADD I V{X}", .{x}) catch "ADD I",
            0x29 => f(buf, "LD F V{X}", .{x}) catch "LD F",
            0x33 => f(buf, "BCD V{X}", .{x}) catch "BCD",
            0x55 => f(buf, "LD [I] V0-V{X}", .{x}) catch "STORE",
            0x65 => f(buf, "LD V0-V{X} [I]", .{x}) catch "LOAD",
            else => "F?",
        },
        else => "?",
    };
}
