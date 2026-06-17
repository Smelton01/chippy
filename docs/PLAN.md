# CHIP-8 Emulator in Zig — Implementation Plan

## Context

`chippy` is a CHIP-8 interpreter built from scratch as a learning exercise,
following the structure of the [Austin Morlan tutorial](https://austinmorlan.com/posts/chip8_emulator/)
but written idiomatically in Zig.

CHIP-8 is an interpreted VM from the 1970s with a tiny, well-documented
instruction set (~35 opcodes), a 64×32 monochrome display, 16 keys, and two
60 Hz timers — an ideal first emulator.

**Decisions:**
- **Platform layer:** raylib via the `raylib-zig` package (fetched & built by
  `zig build` — no system install; provides window, keyboard input, audio beep).
- **Behavior variant:** Modern / SUPER-CHIP quirks for the ambiguous opcodes
  (`8XY6`/`8XYE` shift VX in place; `FX55`/`FX65` leave I unchanged).
- **Toolchain:** Zig `0.16.0-dev`. New build API: modules via `b.createModule(...)`
  passed to `b.addExecutable(.{ .root_module = ... })`.

## Architecture

```
chippy/
├── build.zig              # new-API build: module + raylib link + test step
├── build.zig.zon          # package manifest + raylib-zig dependency
├── src/
│   ├── main.zig           # entry: arg parsing, main loop, timing, glue
│   ├── chip8.zig          # the VM/core (state + fetch-decode-execute)
│   └── platform.zig       # raylib wrapper: render 64x32, map keys, beep
├── docs/PLAN.md           # this document
├── roms/                  # test ROMs (gitignored)
└── README.md              # build/run instructions
```

### Modularity & testability (design rules)

- **The VM core (`chip8.zig`) imports nothing from raylib or the OS event loop.**
  Pure state machine: input is the `keypad` array, output is the `video` buffer
  and `sound_timer`. This seam makes the whole thing testable.
- **Determinism is injectable.** `Chip8.init` takes a `seed`; `loadRom` takes
  bytes, not a path (file reading lives in `main.zig`). Tests construct a VM,
  write opcodes straight into `memory`, call `cycle()`, and assert — no I/O, no
  randomness surprises.
- **Platform is behind a narrow interface, not called by the core.** `main.zig`
  owns the loop and bridges core↔platform; swapping raylib for a terminal or a
  headless double touches only `platform.zig` + a few lines of `main.zig`.
- **Tests live next to the code** (`test "..." {}` in `chip8.zig`) and run via
  `zig build test` with no window.
- One responsibility per file; `main.zig` stays thin glue.

### `chip8.zig` — the VM core

State: `registers [16]u8` (V0–VF), `memory [4096]u8`, `index u16`, `pc u16`,
`stack [16]u16`, `sp u8`, `delay_timer u8`, `sound_timer u8`, `keypad [16]`,
`video [64*32]` framebuffer.

Functions: `init(seed)` (pc=0x200, load fontset at 0x50), `loadRom(bytes)`,
`cycle()` (fetch `mem[pc]<<8 | mem[pc+1]`, `pc += 2`, decode by nibble,
dispatch, execute), `decrementTimers()` (called at 60 Hz).

Dispatch: a `switch` on the high nibble with nested switches for `0x0/0x8/0xE/0xF`
families. ~35 opcodes, wrapping arithmetic (`+%`), explicit VF carry/borrow.
`DXYN` does XOR sprite blit with collision + wrapping. `CXNN` uses a seeded
`std.Random`. Modern quirks for `8XY6/8XYE/FX55/FX65`.

### `platform.zig` — raylib I/O

`init(title, scale)`, `update(video)` (upload 64×32 to a texture, draw scaled),
`processInput(keypad)` (map 1234/QWER/ASDF/ZXCV → 0x0–0xF; quit on ESC/close),
`beep(on)`, `deinit()`.

### `main.zig` — driver

Args: `chippy <rom> [scale] [cycles_per_frame]`. Loop: poll input → run N
`cycle()`s → `decrementTimers()` once per frame → render → beep, locked to 60 Hz
via `setTargetFPS(60)`.

## Implementation steps

0. **Persist this plan** to `docs/PLAN.md`. ✅
1. **Scaffold + build green.** `build.zig`, `build.zig.zon`, stub `main.zig`.
2. **Wire raylib.** Open a blank window, confirm 0.16 compat.
3. **VM skeleton.** struct + `init` + fontset + `loadRom`, with a test.
4. **Fetch-decode-execute + IBM-logo opcodes** (`00E0,1NNN,6XNN,7XNN,ANNN,DXYN`).
5. **Full opcode set** with modern quirks.
6. **Input + audio + 60 Hz timing.**
7. **Verify with test ROMs** (corax+, a game) + README.

## Verification

- `zig build test` — VM core unit tests (opcodes, flags, fontset/ROM load).
- `zig build run -- roms/ibm-logo.ch8` — IBM logo renders (milestone 4).
- `zig build run -- roms/corax-plus.ch8` — opcode test ROM passes.
- Manual: run a game (Pong/Tetris) — input, timing, beep all work.
- Test ROMs: [Timendus chip8-test-suite](https://github.com/Timendus/chip8-test-suite)
  and public-domain games; download sources noted in README.
