//! chippy — a CHIP-8 emulator. Launches into a menu (IBM-logo welcome + ROM
//! picker); pick a game, or pass one on the command line to start it directly.
//!
//! Usage: chippy [rom] [--scale N] [--cycles N] [--roms DIR]
//!   rom        optional .ch8 to load directly (skips the menu until BACKSPACE)
//!   --scale    window pixels per CHIP-8 pixel (default 10)
//!   --cycles   instructions per 60 Hz frame (default 10)
//!   --roms     directory the menu lists ROMs from (default "roms")
//!
//! In-app controls:
//!   menu     up/down move · enter load · R random · esc quit
//!   running  SPACE pause/debug · TAB registers · BACKSPACE menu
//!   debug    N or right step · SPACE resume · BACKSPACE menu

const std = @import("std");
const build_options = @import("build_options");
const App = @import("app.zig").App;

/// Selected at comptime by `-Dbackend`. Only the chosen file is analyzed, so a
/// terminal build never imports or links raylib.
const Backend = switch (build_options.backend) {
    .raylib => @import("backend_raylib.zig").Backend,
    .terminal => @import("backend_terminal.zig").Backend,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit(); // arg slices (rom_dir, rom_path) stay valid until here

    _ = args.next(); // program name
    var scale: i32 = 10;
    var cycles: u32 = 10;
    var rom_dir: []const u8 = "roms";
    var rom_path: ?[]const u8 = null;
    var shot: ?[]const u8 = null; // verification: save screenshots and exit
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--scale")) {
            if (args.next()) |v| scale = std.fmt.parseInt(i32, v, 10) catch scale;
        } else if (std.mem.eql(u8, a, "--cycles")) {
            if (args.next()) |v| cycles = std.fmt.parseInt(u32, v, 10) catch cycles;
        } else if (std.mem.eql(u8, a, "--roms")) {
            if (args.next()) |v| rom_dir = v;
        } else if (std.mem.eql(u8, a, "--shot")) {
            if (args.next()) |v| shot = v;
        } else if (!std.mem.startsWith(u8, a, "--") and rom_path == null) {
            rom_path = a;
        }
    }
    scale = std.math.clamp(scale, 1, 100);

    var backend = try Backend.init(gpa, scale);
    defer backend.deinit();

    var app = try App(Backend).init(gpa, io, &backend, rom_dir, cycles);
    defer app.deinit();

    if (shot) |prefix| {
        app.capture(prefix); // render menu/running/debug to PNGs, then exit
        return;
    }

    if (rom_path) |p| app.loadPath(p); // start a given ROM immediately

    app.run();
}
