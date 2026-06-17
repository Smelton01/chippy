// Browser harness for the chippy WebAssembly core (src/wasm.zig). JS owns the
// loop, rendering, input, and audio; the wasm module is the CHIP-8 VM.

const WIDTH = 64, HEIGHT = 32;

// Physical key -> CHIP-8 keypad index (standard 1234/QWER/ASDF/ZXCV layout).
const KEYMAP = {
  "1": 0x1, "2": 0x2, "3": 0x3, "4": 0xC,
  "q": 0x4, "w": 0x5, "e": 0x6, "r": 0xD,
  "a": 0x7, "s": 0x8, "d": 0x9, "f": 0xE,
  "z": 0xA, "x": 0x0, "c": 0xB, "v": 0xF,
};

const $ = (id) => document.getElementById(id);
const screen = $("screen");
const ctx = screen.getContext("2d");
const image = ctx.createImageData(WIDTH, HEIGHT);

let wasm = null;       // exports
let video = null;      // Uint8Array view over the framebuffer
let running = true;
let cyclesPerFrame = 12;
let lastRom = null;    // Uint8Array of the current ROM (null = built-in IBM)

// --- audio: a square-wave beep gated by the sound timer ---------------------
let audio = null, gain = null;
function ensureAudio() {
  if (audio) return;
  audio = new (window.AudioContext || window.webkitAudioContext)();
  const osc = audio.createOscillator();
  osc.type = "square";
  osc.frequency.value = 440;
  gain = audio.createGain();
  gain.gain.value = 0;
  osc.connect(gain).connect(audio.destination);
  osc.start();
}

// --- rendering --------------------------------------------------------------
function draw() {
  const data = image.data;
  for (let i = 0; i < WIDTH * HEIGHT; i++) {
    const on = video[i] ? 255 : 0;
    const o = i * 4;
    data[o] = on; data[o + 1] = on; data[o + 2] = on; data[o + 3] = 255;
  }
  ctx.putImageData(image, 0, 0);
}

// --- debug panel ------------------------------------------------------------
const debugEl = $("debug");
function updateDebug() {
  if (!debugEl.classList.contains("on")) return;
  const hx = (n, w) => n.toString(16).toUpperCase().padStart(w, "0");
  let regs = "";
  for (let i = 0; i < 16; i++) regs += `V${hx(i, 1)} ${hx(wasm.getReg(i), 2)} `;
  debugEl.textContent =
    `${running ? "[run]" : "[PAUSED]"}  PC 0x${hx(wasm.getPC(), 3)}  OP 0x${hx(wasm.peekOpcode(), 4)}\n` +
    `I 0x${hx(wasm.getIndex(), 3)}   SP ${wasm.getSP()}   DT ${wasm.getDT()}   ST ${wasm.getST()}\n` +
    regs;
}

// --- main loop --------------------------------------------------------------
function frame() {
  if (running) wasm.step(cyclesPerFrame);
  draw();
  if (gain) gain.gain.value = wasm.soundActive() ? 0.06 : 0;
  updateDebug();
  requestAnimationFrame(frame);
}

// --- ROM loading ------------------------------------------------------------
function loadBytes(bytes) {
  lastRom = bytes;
  const cap = wasm.romBufferLen();
  const n = Math.min(bytes.length, cap);
  new Uint8Array(wasm.memory.buffer, wasm.romBufferPtr(), cap).set(bytes.subarray(0, n));
  const ok = wasm.loadRom(n);
  status(ok ? `loaded ROM (${n} bytes)` : "ROM too large");
  running = true;
  syncButtons();
}
function loadDefault() {
  lastRom = null;
  wasm.loadDefault();
  status("running built-in IBM logo · load a ROM to play");
  running = true;
  syncButtons();
}

// --- UI ---------------------------------------------------------------------
function status(s) { $("status").textContent = s; }
function syncButtons() {
  $("pause").textContent = running ? "⏸ Pause" : "▶ Resume";
  $("stepBtn").disabled = running;
}

$("pause").onclick = () => { running = !running; syncButtons(); updateDebug(); };
$("stepBtn").onclick = () => { if (!running) { wasm.cycleOnce(); draw(); updateDebug(); } };
$("reset").onclick = () => { lastRom ? loadBytes(lastRom) : loadDefault(); };
$("dbg").onclick = () => { debugEl.classList.toggle("on"); updateDebug(); };
$("ibm").onclick = () => loadDefault();
$("file").onchange = async (ev) => {
  const f = ev.target.files[0];
  if (f) loadBytes(new Uint8Array(await f.arrayBuffer()));
};
$("speed").oninput = (ev) => {
  cyclesPerFrame = +ev.target.value;
  $("speedval").textContent = `${cyclesPerFrame} cyc/frame`;
};

// --- input ------------------------------------------------------------------
window.addEventListener("keydown", (e) => {
  ensureAudio(); // first user gesture unlocks audio
  const k = KEYMAP[e.key.toLowerCase()];
  if (k !== undefined) { wasm.setKey(k, 1); e.preventDefault(); }
});
window.addEventListener("keyup", (e) => {
  const k = KEYMAP[e.key.toLowerCase()];
  if (k !== undefined) { wasm.setKey(k, 0); e.preventDefault(); }
});

// --- boot -------------------------------------------------------------------
(async () => {
  try {
    let res;
    try {
      res = await WebAssembly.instantiateStreaming(fetch("chippy.wasm"), {});
    } catch {
      // Fallback for servers that don't send the application/wasm MIME type.
      const bytes = await (await fetch("chippy.wasm")).arrayBuffer();
      res = await WebAssembly.instantiate(bytes, {});
    }
    wasm = res.instance.exports;
    video = new Uint8Array(wasm.memory.buffer, wasm.videoPtr(), wasm.videoLen());
    loadDefault();
    syncButtons();
    requestAnimationFrame(frame);
  } catch (err) {
    status("failed to load chippy.wasm — serve this folder over http (see README): " + err);
  }
})();
