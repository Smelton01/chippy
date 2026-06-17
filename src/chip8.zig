//! CHIP-8 virtual machine core.
//!
//! Pure state machine: no raylib, no OS, no file I/O. Inputs are the `keypad`
//! array (set by the platform each frame); outputs are the `video` framebuffer
//! and `sound_timer`. This seam is what keeps the VM testable in isolation
//! (`zig build test`) — see the tests at the bottom of this file.
//!
//! Behavior variant: modern / SUPER-CHIP quirks for the ambiguous opcodes —
//!   * 8XY6 / 8XYE shift VX in place (VY is ignored)
//!   * FX55 / FX65 leave the index register I unchanged
//!   * 8XY1/2/3 do NOT reset VF

const std = @import("std");

pub const video_width = 64;
pub const video_height = 32;

const memory_size = 4096;
const rom_start = 0x200;
const fontset_start = 0x50;

/// 16 hex characters, 5 bytes (an 8x5 sprite) each.
const fontset = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

pub const Chip8 = struct {
    memory: [memory_size]u8 = [_]u8{0} ** memory_size,
    v: [16]u8 = [_]u8{0} ** 16, // V0..VF; VF doubles as the flag register
    index: u16 = 0, // address register "I"
    pc: u16 = rom_start, // program counter
    stack: [16]u16 = [_]u16{0} ** 16,
    sp: u8 = 0, // stack pointer
    delay_timer: u8 = 0,
    sound_timer: u8 = 0,
    keypad: [16]bool = [_]bool{false} ** 16,
    video: [video_width * video_height]bool = [_]bool{false} ** (video_width * video_height),
    /// Set true whenever the framebuffer changed; the platform may use it to
    /// avoid redundant texture uploads.
    draw_flag: bool = false,
    prng: std.Random.DefaultPrng,

    /// `seed` makes CXNN (random) deterministic for tests.
    pub fn init(seed: u64) Chip8 {
        var c = Chip8{ .prng = std.Random.DefaultPrng.init(seed) };
        @memcpy(c.memory[fontset_start..][0..fontset.len], &fontset);
        return c;
    }

    /// Load program bytes at 0x200. Takes bytes (not a path) so the core stays
    /// free of file I/O — `main.zig` reads the file and passes the slice.
    pub fn loadRom(self: *Chip8, bytes: []const u8) error{RomTooLarge}!void {
        if (bytes.len > memory_size - rom_start) return error.RomTooLarge;
        @memcpy(self.memory[rom_start..][0..bytes.len], bytes);
    }

    /// Decrement both timers; call at 60 Hz. Sound plays while sound_timer > 0.
    pub fn decrementTimers(self: *Chip8) void {
        if (self.delay_timer > 0) self.delay_timer -= 1;
        if (self.sound_timer > 0) self.sound_timer -= 1;
    }

    inline fn mem(self: *Chip8, addr: u16) *u8 {
        return &self.memory[addr & 0x0FFF];
    }

    /// Fetch one instruction, advance PC, decode and execute it.
    pub fn cycle(self: *Chip8) void {
        const hi: u16 = self.mem(self.pc).*;
        const lo: u16 = self.mem(self.pc +% 1).*;
        const opcode: u16 = (hi << 8) | lo;
        self.pc +%= 2;

        const x: u4 = @truncate(opcode >> 8);
        const y: u4 = @truncate(opcode >> 4);
        const n: u4 = @truncate(opcode);
        const nn: u8 = @truncate(opcode);
        const nnn: u12 = @truncate(opcode);

        switch (opcode & 0xF000) {
            0x0000 => switch (nn) {
                0xE0 => { // 00E0: clear screen
                    @memset(&self.video, false);
                    self.draw_flag = true;
                },
                0xEE => { // 00EE: return from subroutine
                    if (self.sp == 0) return; // empty stack: ignore (malformed ROM)
                    self.sp -= 1;
                    self.pc = self.stack[self.sp];
                },
                else => {}, // 0NNN (machine code call) is unsupported; ignore
            },
            0x1000 => self.pc = nnn, // 1NNN: jump
            0x2000 => { // 2NNN: call subroutine
                if (self.sp >= self.stack.len) return; // stack full: ignore (malformed ROM)
                self.stack[self.sp] = self.pc;
                self.sp += 1;
                self.pc = nnn;
            },
            0x3000 => if (self.v[x] == nn) {
                self.pc +%= 2;
            }, // 3XNN: skip if VX == NN
            0x4000 => if (self.v[x] != nn) {
                self.pc +%= 2;
            }, // 4XNN: skip if VX != NN
            0x5000 => if (self.v[x] == self.v[y]) {
                self.pc +%= 2;
            }, // 5XY0: skip if VX == VY
            0x6000 => self.v[x] = nn, // 6XNN: VX = NN
            0x7000 => self.v[x] +%= nn, // 7XNN: VX += NN (no carry)
            0x8000 => self.arithmetic(x, y, n),
            0x9000 => if (self.v[x] != self.v[y]) {
                self.pc +%= 2;
            }, // 9XY0: skip if VX != VY
            0xA000 => self.index = nnn, // ANNN: I = NNN
            0xB000 => self.pc = @as(u16, nnn) +% self.v[0], // BNNN: jump to NNN + V0
            0xC000 => self.v[x] = self.prng.random().int(u8) & nn, // CXNN: VX = rand & NN
            0xD000 => self.draw(x, y, n), // DXYN: draw sprite
            0xE000 => switch (nn) {
                0x9E => if (self.keypad[self.v[x] & 0x0F]) {
                    self.pc +%= 2;
                }, // EX9E: skip if key VX down
                0xA1 => if (!self.keypad[self.v[x] & 0x0F]) {
                    self.pc +%= 2;
                }, // EXA1: skip if key VX up
                else => {},
            },
            0xF000 => self.misc(x, nn),
            else => unreachable,
        }
    }

    /// 8XY_ ALU family.
    fn arithmetic(self: *Chip8, x: u4, y: u4, n: u4) void {
        const vx = self.v[x];
        const vy = self.v[y];
        switch (n) {
            0x0 => self.v[x] = vy, // VX = VY
            0x1 => self.v[x] = vx | vy, // VX |= VY
            0x2 => self.v[x] = vx & vy, // VX &= VY
            0x3 => self.v[x] = vx ^ vy, // VX ^= VY
            0x4 => { // VX += VY, VF = carry
                const sum: u16 = @as(u16, vx) + vy;
                self.v[x] = @truncate(sum);
                self.v[0xF] = if (sum > 0xFF) 1 else 0;
            },
            0x5 => { // VX -= VY, VF = NOT borrow
                self.v[x] = vx -% vy;
                self.v[0xF] = if (vx >= vy) 1 else 0;
            },
            0x6 => { // VX >>= 1, VF = shifted-out bit (modern: operate on VX)
                self.v[x] = vx >> 1;
                self.v[0xF] = vx & 1;
            },
            0x7 => { // VX = VY - VX, VF = NOT borrow
                self.v[x] = vy -% vx;
                self.v[0xF] = if (vy >= vx) 1 else 0;
            },
            0xE => { // VX <<= 1, VF = shifted-out bit (modern: operate on VX)
                self.v[x] = vx << 1;
                self.v[0xF] = (vx >> 7) & 1;
            },
            else => {},
        }
    }

    /// DXYN: XOR an N-byte sprite at (VX, VY); VF = collision. The start
    /// position wraps, but pixels past the right/bottom edge are clipped.
    /// DXY0 (n == 0) draws zero rows — a no-op here. This is a 64x32 lores-only
    /// emulator; the SUPER-CHIP hires 16x16-sprite meaning of DXY0 is out of scope.
    fn draw(self: *Chip8, x: u4, y: u4, n: u4) void {
        const x0: usize = self.v[x] % video_width;
        const y0: usize = self.v[y] % video_height;
        self.v[0xF] = 0;
        var row: usize = 0;
        while (row < n) : (row += 1) {
            const py = y0 + row;
            if (py >= video_height) break; // clip bottom
            const sprite = self.mem(self.index +% @as(u16, @intCast(row))).*;
            var col: usize = 0;
            while (col < 8) : (col += 1) {
                if ((sprite >> @intCast(7 - col)) & 1 == 0) continue;
                const px = x0 + col;
                if (px >= video_width) continue; // clip right
                const idx = py * video_width + px;
                if (self.video[idx]) self.v[0xF] = 1; // collision
                self.video[idx] = !self.video[idx]; // XOR
            }
        }
        self.draw_flag = true;
    }

    /// FX__ family: timers, keys, memory, BCD, font.
    fn misc(self: *Chip8, x: u4, nn: u8) void {
        switch (nn) {
            0x07 => self.v[x] = self.delay_timer, // VX = delay
            0x0A => { // wait for a key press, store in VX
                for (self.keypad, 0..) |down, k| {
                    if (down) {
                        self.v[x] = @intCast(k);
                        return;
                    }
                }
                self.pc -%= 2; // no key: re-run this instruction next cycle
            },
            0x15 => self.delay_timer = self.v[x], // delay = VX
            0x18 => self.sound_timer = self.v[x], // sound = VX
            0x1E => self.index +%= self.v[x], // I += VX
            0x29 => self.index = fontset_start + @as(u16, self.v[x] & 0x0F) * 5, // I = font(VX)
            0x33 => { // BCD of VX into I, I+1, I+2
                self.mem(self.index).* = self.v[x] / 100;
                self.mem(self.index +% 1).* = (self.v[x] / 10) % 10;
                self.mem(self.index +% 2).* = self.v[x] % 10;
            },
            0x55 => { // store V0..VX at [I] (modern: I unchanged)
                var i: usize = 0;
                while (i <= x) : (i += 1) self.mem(self.index +% @as(u16, @intCast(i))).* = self.v[i];
            },
            0x65 => { // load V0..VX from [I] (modern: I unchanged)
                var i: usize = 0;
                while (i <= x) : (i += 1) self.v[i] = self.mem(self.index +% @as(u16, @intCast(i))).*;
            },
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests — run with `zig build test` (no window, no I/O).
// ---------------------------------------------------------------------------
const testing = std.testing;

/// Helper: build a VM with a single opcode at 0x200 and step once.
fn runOne(opcode: u16) Chip8 {
    var c = Chip8.init(0);
    c.memory[0x200] = @truncate(opcode >> 8);
    c.memory[0x201] = @truncate(opcode);
    c.cycle();
    return c;
}

test "init: pc, fontset, and zeroed state" {
    const c = Chip8.init(0);
    try testing.expectEqual(@as(u16, 0x200), c.pc);
    try testing.expectEqual(@as(u8, 0xF0), c.memory[fontset_start]); // first byte of '0'
    try testing.expectEqual(@as(u8, 0x80), c.memory[fontset_start + 79]); // last byte of 'F'
    try testing.expectEqual(@as(u16, 0), c.index);
    try testing.expectEqual(@as(u8, 0), c.v[0]);
}

test "loadRom: bytes land at 0x200, oversize rejected" {
    var c = Chip8.init(0);
    try c.loadRom(&[_]u8{ 0xAB, 0xCD });
    try testing.expectEqual(@as(u8, 0xAB), c.memory[0x200]);
    try testing.expectEqual(@as(u8, 0xCD), c.memory[0x201]);

    var c2 = Chip8.init(0);
    const huge = [_]u8{0} ** (memory_size - rom_start + 1);
    try testing.expectError(error.RomTooLarge, c2.loadRom(&huge));
}

test "6XNN sets register, 7XNN adds with wraparound" {
    var c = runOne(0x6A05); // VA = 5
    try testing.expectEqual(@as(u8, 5), c.v[0xA]);
    c.v[0] = 250;
    c.memory[0x202] = 0x70;
    c.memory[0x203] = 0x10; // 7010: V0 += 16 -> wraps to 10
    c.cycle();
    try testing.expectEqual(@as(u8, 10), c.v[0]);
}

test "1NNN jump and 2NNN/00EE call+return" {
    var c = Chip8.init(0);
    c.memory[0x200] = 0x22;
    c.memory[0x201] = 0x06; // 2206: call 0x206
    c.memory[0x206] = 0x00;
    c.memory[0x207] = 0xEE; // 00EE: return
    c.cycle();
    try testing.expectEqual(@as(u16, 0x206), c.pc);
    try testing.expectEqual(@as(u8, 1), c.sp);
    c.cycle(); // return
    try testing.expectEqual(@as(u16, 0x202), c.pc);
    try testing.expectEqual(@as(u8, 0), c.sp);
}

test "3XNN/4XNN conditional skips" {
    var c = runOne(0x3000); // V0(=0)==0 -> skip, pc 0x200 -> +2 (fetch) +2 (skip)
    try testing.expectEqual(@as(u16, 0x204), c.pc);
    c = runOne(0x4000); // V0==0 so NOT != -> no skip
    try testing.expectEqual(@as(u16, 0x202), c.pc);
}

test "8XY4 add sets carry flag" {
    var c = Chip8.init(0);
    c.v[0] = 200;
    c.v[1] = 100;
    c.memory[0x200] = 0x80;
    c.memory[0x201] = 0x14; // 8014: V0 += V1
    c.cycle();
    try testing.expectEqual(@as(u8, 44), c.v[0]); // 300 & 0xFF
    try testing.expectEqual(@as(u8, 1), c.v[0xF]); // carry
}

test "8XY5 subtract sets NOT-borrow flag" {
    var c = Chip8.init(0);
    c.v[0] = 10;
    c.v[1] = 3;
    c.memory[0x200] = 0x80;
    c.memory[0x201] = 0x15; // V0 -= V1
    c.cycle();
    try testing.expectEqual(@as(u8, 7), c.v[0]);
    try testing.expectEqual(@as(u8, 1), c.v[0xF]); // no borrow
}

test "8XY6 modern quirk: shifts VX in place, VF = lost bit" {
    var c = Chip8.init(0);
    c.v[0] = 0b0000_0101;
    c.v[1] = 0xFF; // VY must be ignored under modern quirk
    c.memory[0x200] = 0x80;
    c.memory[0x201] = 0x16; // 8016: V0 >>= 1
    c.cycle();
    try testing.expectEqual(@as(u8, 0b0000_0010), c.v[0]);
    try testing.expectEqual(@as(u8, 1), c.v[0xF]); // LSB was 1
}

test "ANNN sets I; FX33 writes BCD; FX65 modern leaves I unchanged" {
    var c = Chip8.init(0);
    c.v[0] = 123;
    // ANNN: I = 0x400
    c.memory[0x200] = 0xA4;
    c.memory[0x201] = 0x00;
    // FX33: BCD of V0
    c.memory[0x202] = 0xF0;
    c.memory[0x203] = 0x33;
    c.cycle();
    c.cycle();
    try testing.expectEqual(@as(u16, 0x400), c.index);
    try testing.expectEqual(@as(u8, 1), c.memory[0x400]);
    try testing.expectEqual(@as(u8, 2), c.memory[0x401]);
    try testing.expectEqual(@as(u8, 3), c.memory[0x402]);
    // FX65: load V0..V2 from [I]; I must be unchanged (modern quirk)
    c.memory[0x204] = 0xF2;
    c.memory[0x205] = 0x65;
    c.cycle();
    try testing.expectEqual(@as(u8, 1), c.v[0]);
    try testing.expectEqual(@as(u8, 2), c.v[1]);
    try testing.expectEqual(@as(u8, 3), c.v[2]);
    try testing.expectEqual(@as(u16, 0x400), c.index); // unchanged
}

test "DXYN draws sprite, sets collision, XORs off on redraw" {
    var c = Chip8.init(0);
    c.index = 0x300;
    c.memory[0x300] = 0b1000_0001; // two pixels: col 0 and col 7
    c.v[0] = 0; // x
    c.v[1] = 0; // y
    c.memory[0x200] = 0xD0;
    c.memory[0x201] = 0x11; // D011: draw 1 row at (V0,V1)
    c.cycle();
    try testing.expect(c.video[0]); // pixel (0,0)
    try testing.expect(c.video[7]); // pixel (7,0)
    try testing.expectEqual(@as(u8, 0), c.v[0xF]); // no collision first time
    try testing.expect(c.draw_flag);
    // draw again at same spot -> pixels turn off, collision flagged
    c.pc = 0x200;
    c.cycle();
    try testing.expect(!c.video[0]);
    try testing.expect(!c.video[7]);
    try testing.expectEqual(@as(u8, 1), c.v[0xF]);
}

test "EX9E/EXA1 key skips and FX0A wait" {
    var c = Chip8.init(0);
    c.v[0] = 0xA;
    c.keypad[0xA] = true;
    c.memory[0x200] = 0xE0;
    c.memory[0x201] = 0x9E; // skip if key A down -> yes
    c.cycle();
    try testing.expectEqual(@as(u16, 0x204), c.pc);

    // FX0A: with no key held, pc should stall (re-run instruction)
    var w = Chip8.init(0);
    w.memory[0x200] = 0xF3;
    w.memory[0x201] = 0x0A;
    w.cycle();
    try testing.expectEqual(@as(u16, 0x200), w.pc); // stalled
    w.keypad[7] = true;
    w.cycle();
    try testing.expectEqual(@as(u8, 7), w.v[3]);
    try testing.expectEqual(@as(u16, 0x202), w.pc);
}

test "00E0 clears screen" {
    var c = Chip8.init(0);
    c.video[42] = true;
    c.memory[0x200] = 0x00;
    c.memory[0x201] = 0xE0;
    c.cycle();
    try testing.expect(!c.video[42]);
    try testing.expect(c.draw_flag);
}

test "malformed ROM: stack underflow/overflow and high-I BCD don't crash" {
    // 00EE on an empty stack must be ignored, not panic.
    const c = runOne(0x00EE);
    try testing.expectEqual(@as(u8, 0), c.sp);

    // 2NNN with a full stack must be ignored, not overflow the 16-entry stack.
    var f = Chip8.init(0);
    f.sp = 16;
    f.memory[0x200] = 0x22;
    f.memory[0x201] = 0x06; // 2206
    f.cycle();
    try testing.expectEqual(@as(u8, 16), f.sp); // unchanged

    // FX33 with I near u16 max must wrap (masked) rather than panic on I+1/I+2.
    var b = Chip8.init(0);
    b.index = 0xFFFF;
    b.v[0] = 123;
    b.memory[0x200] = 0xF0;
    b.memory[0x201] = 0x33;
    b.cycle();
    try testing.expectEqual(@as(u8, 1), b.memory[0xFFFF & 0x0FFF]);
    try testing.expectEqual(@as(u8, 2), b.memory[0x000 & 0x0FFF]); // (0xFFFF +% 1) & 0xFFF
    try testing.expectEqual(@as(u8, 3), b.memory[0x001 & 0x0FFF]);
}

test "decrementTimers floors at zero" {
    var c = Chip8.init(0);
    c.delay_timer = 1;
    c.sound_timer = 0;
    c.decrementTimers();
    try testing.expectEqual(@as(u8, 0), c.delay_timer);
    try testing.expectEqual(@as(u8, 0), c.sound_timer);
}
