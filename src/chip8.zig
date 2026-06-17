//! CHIP-8 virtual machine core.
//!
//! Pure state machine: no raylib, no OS, no file I/O. Input is the `keypad`
//! array; output is the `video` framebuffer and `sound_timer`. This is the seam
//! that keeps the VM testable in isolation (see `zig build test`).

const std = @import("std");

// (state, fontset, init, loadRom, cycle land here in the next steps)

test "placeholder — core builds and tests run" {
    try std.testing.expect(true);
}
