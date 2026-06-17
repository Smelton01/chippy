//! WebAssembly entry point: a thin C-ABI shim over the (backend-free) CHIP-8
//! core for the browser. The loop, rendering, input, and audio live in JS
//! (web/chip8.js) — JS owns requestAnimationFrame and calls `step()` each frame,
//! reads the framebuffer out of linear memory, and pushes key state in.
//!
//! Built with `zig build wasm` (wasm32-freestanding). No OS, no allocator —
//! the VM is a fixed struct living in linear memory.

const std = @import("std");
const chip8 = @import("chip8.zig");
const ibm = @import("ibm_logo.zig");

/// Freestanding wasm has no OS to print to or abort; trap on panic.
pub const panic = std.debug.FullPanic(struct {
    fn panic(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.panic);

var vm: chip8.Chip8 = undefined;

/// Scratch buffer JS writes ROM bytes into before calling `loadRom`.
var rom_buf: [4096 - 0x200]u8 = undefined;

export fn romBufferPtr() [*]u8 {
    return &rom_buf;
}
export fn romBufferLen() usize {
    return rom_buf.len;
}

/// Load `len` bytes previously written to `romBufferPtr()`. Returns false if
/// the ROM is too large. Seeds CXNN's PRNG from the ROM bytes.
export fn loadRom(len: usize) bool {
    const bytes = rom_buf[0..@min(len, rom_buf.len)];
    vm = chip8.Chip8.init(std.hash.Wyhash.hash(0, bytes));
    vm.loadRom(bytes) catch return false;
    return true;
}

/// Load the built-in IBM-logo ROM (so the page shows something immediately).
export fn loadDefault() void {
    vm = chip8.Chip8.init(0);
    vm.loadRom(&ibm.ibm_logo) catch {};
}

/// Set one of the 16 keypad keys up/down (browser provides real keyup events).
export fn setKey(i: u32, down: bool) void {
    if (i < 16) vm.keypad[i] = down;
}

/// Run one 60 Hz frame: `cycles` instructions, then tick the timers once.
export fn step(cycles: u32) void {
    var n: u32 = 0;
    while (n < cycles) : (n += 1) vm.cycle();
    vm.decrementTimers();
}

/// Execute exactly one instruction (no timer tick) — for the debugger's step.
export fn cycleOnce() void {
    vm.cycle();
}

/// Pointer/length of the 64*32 framebuffer (one byte per pixel, 0 or 1).
export fn videoPtr() [*]const bool {
    return &vm.video;
}
export fn videoLen() usize {
    return vm.video.len;
}
export fn videoWidth() u32 {
    return chip8.video_width;
}
export fn videoHeight() u32 {
    return chip8.video_height;
}

/// True while the sound timer is running (JS drives the beep).
export fn soundActive() bool {
    return vm.sound_timer > 0;
}

// --- debugger getters (the DOM debug panel reads these) ---------------------
export fn getPC() u16 {
    return vm.pc;
}
export fn getIndex() u16 {
    return vm.index;
}
export fn getSP() u8 {
    return vm.sp;
}
export fn getDT() u8 {
    return vm.delay_timer;
}
export fn getST() u8 {
    return vm.sound_timer;
}
export fn getReg(i: u32) u8 {
    return if (i < 16) vm.v[i] else 0;
}
export fn peekOpcode() u16 {
    const hi: u16 = vm.memory[vm.pc & 0x0FFF];
    const lo: u16 = vm.memory[(vm.pc +% 1) & 0x0FFF];
    return (hi << 8) | lo;
}
