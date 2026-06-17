//! chippy — a CHIP-8 emulator. Thin driver: parse args, load the ROM, then run
//! the 60 Hz loop bridging the VM core (chip8.zig) and the platform (raylib).
//!
//! Usage: chippy <rom> [scale] [cycles_per_frame]
//!   scale            window pixel size per CHIP-8 pixel (default 10 -> 640x320)
//!   cycles_per_frame CPU instructions executed per 60 Hz frame (default 10)
//!
//! Zig 0.16 note: `main` takes a `std.process.Init` to reach argv + Io + the
//! allocator (a zero-arg main cannot read argv under the std.Io refactor).

const std = @import("std");
const chip8 = @import("chip8.zig");
const platform = @import("platform.zig");

const default_scale: i32 = 10;
const default_cycles: u32 = 10;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // The arg iterator's slices stay valid until it.deinit(); we read the ROM
    // before then, so there's no need to dupe rom_path.
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    const prog = args.next() orelse "chippy";
    const rom_path = args.next() orelse {
        std.debug.print("usage: {s} <rom> [scale] [cycles_per_frame]\n", .{prog});
        std.process.exit(1);
    };
    const scale: i32 = if (args.next()) |s| std.fmt.parseInt(i32, s, 10) catch default_scale else default_scale;
    const cycles_per_frame: u32 = if (args.next()) |s| std.fmt.parseInt(u32, s, 10) catch default_cycles else default_cycles;

    // Read ROM bytes (file I/O stays out of the VM core).
    const rom = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(64 * 1024)) catch |err| {
        std.debug.print("error: cannot read ROM '{s}': {s}\n", .{ rom_path, @errorName(err) });
        std.process.exit(1);
    };
    defer gpa.free(rom);

    // Seed CXNN's PRNG from the ROM bytes: varies per game, reproducible per run.
    var vm = chip8.Chip8.init(std.hash.Wyhash.hash(0, rom));
    vm.loadRom(rom) catch {
        std.debug.print("error: ROM too large ({d} bytes, max {d})\n", .{ rom.len, 4096 - 0x200 });
        std.process.exit(1);
    };

    var plat = platform.Platform.init(scale);
    defer plat.deinit();

    while (!plat.shouldClose()) {
        plat.pollKeys(&vm.keypad);

        var i: u32 = 0;
        while (i < cycles_per_frame) : (i += 1) vm.cycle();

        vm.decrementTimers(); // once per frame == 60 Hz
        plat.render(&vm.video);
        plat.updateSound(vm.sound_timer);
    }
}
