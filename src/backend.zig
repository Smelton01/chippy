//! The backend interface — the seam that lets the app render and take input on
//! different "screens" (raylib desktop, terminal, and a future WASM/web build).
//!
//! A backend is any type `B` that exposes the method set checked by `verify()`.
//! `App(comptime Backend)` in app.zig is generic over it; `main.zig` picks the
//! concrete backend at comptime via the `-Dbackend` build flag, so an
//! unselected backend (and its dependencies, e.g. raylib) is never compiled.
//!
//! The API is deliberately *semantic* rather than pixel- or character-specific:
//!   - `drawDisplay(video)` renders the 64x32 monochrome buffer in the main area
//!   - `panelLine(row, style, text)` writes one line of the info panel
//!   - `actionPressed(action)` / `pollEmuKeys(keypad)` abstract input
//! so a pixel renderer, a character grid, and a JS-driven canvas can all comply.

/// Edge-triggered UI controls (one tap = one event), independent of any keymap.
pub const Action = enum {
    up,
    down,
    select,
    random,
    quit,
    pause_resume,
    step,
    toggle_regs,
    back,
};

/// Logical text styles; each backend maps these to colors / attributes.
pub const Style = enum {
    normal,
    dim,
    accent,
    highlight,
    err,
};

/// Required backend methods (signatures shown in comments):
///   init(gpa: std.mem.Allocator, scale: i32) !B
///   deinit(*B) void
///   shouldClose(*B) bool
///   beginFrame(*B) void
///   endFrame(*B) void
///   drawDisplay(*B, video: []const bool) void   // 64x32 monochrome buffer
///   panelRows(*B) usize                          // text lines the panel fits
///   panelLine(*B, row: usize, style: Style, text: [:0]const u8) void
///   actionPressed(*B, action: Action) bool
///   pollEmuKeys(*B, keypad: *[16]bool) void
///   setBeep(*B, on: bool) void
/// Optional:
///   screenshot(*B, path: [:0]const u8) void      // raylib only; app @hasDecl-guards
pub fn verify(comptime B: type) void {
    const required = [_][]const u8{
        "init",        "deinit",     "shouldClose", "beginFrame", "endFrame",
        "drawDisplay", "panelRows",  "panelLine",   "actionPressed",
        "pollEmuKeys", "setBeep",
    };
    inline for (required) |name| {
        if (!@hasDecl(B, name)) {
            @compileError("backend " ++ @typeName(B) ++ " is missing required method: " ++ name);
        }
    }
}
