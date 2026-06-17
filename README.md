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
zig build run -- <rom>          # run a ROM
zig build run -- <rom> <scale> <cycles_per_frame>
zig build test                  # run the VM core unit tests
```

- `scale` — window pixels per CHIP-8 pixel (default `10` → 640×320 window).
- `cycles_per_frame` — instructions executed per 60 Hz frame (default `10`;
  bump to ~15–30 for faster games).

Example:

```sh
zig build run -- roms/2-ibm-logo.ch8
zig build run -- roms/3-corax+.ch8 12 20
```

Close the window or press <kbd>Esc</kbd> to quit.

## Controls

The original CHIP-8 hex keypad is mapped to the left of a QWERTY keyboard:

```
 CHIP-8 keypad        Your keyboard
 1 2 3 C              1 2 3 4
 4 5 6 D     <-->     Q W E R
 7 8 9 E              A S D F
 A 0 B F              Z X C V
```

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
src/platform.zig  raylib layer — render, keypad, beep
src/main.zig      driver — args, ROM load, 60 Hz loop
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
