# chippy

A [CHIP-8](https://en.wikipedia.org/wiki/CHIP-8) emulator written from scratch in
Zig, using [raylib](https://www.raylib.com/) (via
[raylib-zig](https://github.com/raylib-zig/raylib-zig)) for the window, input,
and sound. Built as a learning project following the structure of
[Austin Morlan's guide](https://austinmorlan.com/posts/chip8_emulator/).

CHIP-8 is a tiny interpreted VM from the 1970s: 4 KB of memory, 16 registers, a
64×32 monochrome display, a 16-key hex keypad, and two 60 Hz timers — about 35
instructions in total.

## Requirements

- **Zig 0.16.0** (exactly). The repo pins it via `.zvmrc` and `minimum_zig_version`.
  If you use [zvm](https://github.com/tristanisham/zvm): `zvm install 0.16.0 && zvm use 0.16.0`.
- No system libraries needed — raylib is fetched and built from source by `zig build`.

> Why pinned? raylib-zig's `devel` branch tracks Zig 0.16.0. Newer nightlies
> change `std`/build APIs that break raylib's build script; older releases
> (≤ 0.15.1) can't link against the macOS 26 SDK. 0.16.0 is the sweet spot.

## Build & run

```sh
zig build                       # build (compiles raylib the first time)
zig build run                   # launch into the menu (ROM picker)
zig build run -- <rom>          # start a ROM directly
zig build test                  # run the VM core unit tests
```

Launched with no ROM, chippy opens a **menu**: the IBM-logo welcome banner above
a list of the `.ch8` files in `./roms`. Pick one to play.

Options (flags, any order; a bare path is a ROM to start directly):

```sh
zig build run -- --scale 12 --cycles 20         # bigger window, faster CPU
zig build run -- roms/3-corax+.ch8              # skip the menu, run this ROM
zig build run -- --roms ~/chip8-games           # list ROMs from elsewhere
```

- `--scale N` — window pixels per CHIP-8 pixel (default `10`).
- `--cycles N` — instructions executed per 60 Hz frame (default `10`; bump to
  ~15–30 for faster games).
- `--roms DIR` — directory the menu lists ROMs from (default `roms`).

## Controls

| Where | Key | Action |
|-------|-----|--------|
| Menu | ↑ / ↓ | move selection |
| Menu | Enter | load selected ROM |
| Menu | `R` | load a random ROM |
| Menu | Esc | quit |
| Running | Space | pause → debugger |
| Running | Tab | toggle register HUD |
| Running | Backspace | back to menu |
| Debug (paused) | `N` / → | step one instruction |
| Debug (paused) | Space | resume |
| Debug (paused) | Backspace | back to menu |

During emulation the CHIP-8 hex keypad is mapped to the left of a QWERTY keyboard:

```
 CHIP-8 keypad        Your keyboard
 1 2 3 C              1 2 3 4
 4 5 6 D     <-->     Q W E R
 7 8 9 E              A S D F
 A 0 B F              Z X C V
```

## Debugger

Press **Space** during a game to pause and open the debugger. The bottom panel
shows the program counter, the current opcode with a one-line disassembly, the
index register `I`, stack pointer, both timers, and all 16 `V` registers. Press
**N** (or →) to execute one instruction at a time and watch the state change;
**Space** resumes, **Backspace** returns to the menu. Press **Tab** while running
to toggle the same register readout live.

## ROMs

ROMs are not committed (see `.gitignore`). Get test ROMs from the
[Timendus CHIP-8 test suite](https://github.com/Timendus/chip8-test-suite)
(`bin/` directory), e.g.:

```sh
mkdir -p roms
curl -L -o roms/2-ibm-logo.ch8 https://github.com/Timendus/chip8-test-suite/raw/main/bin/2-ibm-logo.ch8
curl -L -o roms/3-corax+.ch8   https://github.com/Timendus/chip8-test-suite/raw/main/bin/3-corax+.ch8
```

Public-domain games (Pong, Tetris, Brix, …) are widely available online; drop any
`.ch8` file into `roms/` and run it.

## Behavior / quirks

Targets the **modern / SUPER-CHIP** interpretation of the ambiguous opcodes:

- `8XY6` / `8XYE` shift `VX` in place (`VY` is ignored).
- `FX55` / `FX65` leave the index register `I` unchanged.
- `8XY1` / `8XY2` / `8XY3` do **not** reset `VF`.
- `BNNN` jumps to `NNN + V0`.

`DXY0` is a no-op (this is a 64×32 lores-only emulator; the SUPER-CHIP hires
16×16 sprite is out of scope).

## Project layout

```
src/chip8.zig     VM core — pure state machine, no raylib/OS/file I/O (unit-tested)
src/platform.zig  raylib layer — window, framebuffer + panel, keypad, beep
src/app.zig       app shell — menu / running / debugger state machine, ROM picker
src/main.zig      entry — arg parsing, wires platform + app
src/ibm_logo.zig  embedded IBM-logo ROM bytes for the welcome banner
docs/PLAN.md      design & implementation plan
```

The core is deliberately decoupled from raylib so it can be tested headlessly and
the renderer can be swapped without touching emulation logic.

## Verification

- `zig build test` — 14 unit tests covering opcode semantics, flags, the chosen
  quirks, sprite draw/collision, and malformed-ROM hardening.
- The IBM-logo, corax+ (opcodes), and flags (VF) test ROMs were cross-checked
  against an independent reference interpreter and render byte-for-byte
  identically — corax+ and flags show all checkmarks.
