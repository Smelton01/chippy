// Headless smoke test for the WebAssembly core (web/chippy.wasm).
// Build first with `zig build wasm`, then run `node web/smoke.mjs`.
// Verifies the module instantiates, runs the built-in IBM logo, and that the
// loadRom + single-step paths behave — no browser needed.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bytes = await readFile(join(here, "chippy.wasm"));
const { instance } = await WebAssembly.instantiate(bytes, {});
const e = instance.exports;

// 1) built-in IBM logo renders.
e.loadDefault();
for (let i = 0; i < 30; i++) e.step(10);
const w = e.videoWidth(), h = e.videoHeight();
const video = new Uint8Array(e.memory.buffer, e.videoPtr(), e.videoLen());
let lit = 0;
for (const px of video) if (px) lit++;

// 2) loadRom + cycleOnce: write `60 05` (LD V0, 05), step one instruction.
const prog = new Uint8Array([0x60, 0x05]);
new Uint8Array(e.memory.buffer, e.romBufferPtr(), e.romBufferLen()).set(prog);
e.loadRom(prog.length);
const pc0 = e.getPC();
e.cycleOnce();

const checks = [
  ["IBM logo lit pixels > 100", lit > 100],
  ["framebuffer is 64x32", w === 64 && h === 32],
  ["loadRom set V0 = 5", e.getReg(0) === 5],
  ["cycleOnce advanced PC by 2", e.getPC() === pc0 + 2],
];

let ok = true;
for (const [name, pass] of checks) {
  console.log(`${pass ? "ok  " : "FAIL"} - ${name}`);
  if (!pass) ok = false;
}
console.log(ok ? "wasm smoke: PASS" : "wasm smoke: FAIL");
process.exit(ok ? 0 : 1);
