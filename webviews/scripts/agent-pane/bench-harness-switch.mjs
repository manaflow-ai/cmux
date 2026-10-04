// Harness switch latency against a live dev slot (dev-slot.sh), in a headless Chromium.
// Every stage is timed on the page clock: the WebSocket frames (patched in before the pane
// loads), the pane's own snapshot (cmuxAcpmuxDebug), and the first frame that paints the new
// harness's model chip.
//
//   bun scripts/agent-pane/bench-harness-switch.mjs --url "<agent pane URL from dev-slot.sh url N>" \
//     [--sequence claude,codex,claude,opencode,codex] [--prompt "Reply with exactly: ok"] [--out FILE]
//
// --prompt also times the first token on each harness (one short real turn per switch).
import fs from "node:fs";
import { chromium } from "playwright";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const url = arg("url");
if (!url) throw new Error("--url is required (dev-slot.sh url N)");
const sequence = arg("sequence", "codex,claude,codex,claude,opencode,codex").split(",");
const prompt = arg("prompt");
const out = arg("out");
const settleMs = Number(arg("settle", 1500));

// Runs in the page before any pane script: every frame with its page time and JSON-RPC shape.
function instrument() {
  const frames = [];
  window.__benchFrames = frames;
  const shape = (data) => {
    try {
      const m = JSON.parse(typeof data === "string" ? data : "");
      return { id: m.id ?? null, method: m.method ?? null, error: m.error ? String(m.error.message) : undefined };
    } catch {
      return { id: null, method: null };
    }
  };
  const Native = window.WebSocket;
  window.WebSocket = class extends Native {
    constructor(...args) {
      super(...args);
      this.addEventListener("message", (event) => {
        const s = shape(event.data);
        frames.push({
          t: performance.now(),
          dir: "in",
          ...s,
          bytes: String(event.data).length,
          data: s.method ? undefined : String(event.data).slice(0, 4000),
        });
      });
    }
    send(data) {
      frames.push({ t: performance.now(), dir: "out", ...shape(data), data: String(data).slice(0, 600) });
      return super.send(data);
    }
  };
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
await page.addInitScript(instrument);
const loadStart = Date.now();
await page.goto(url.includes("&new") ? url : `${url}&new`);
await page.waitForFunction(() => window.cmuxAcpmuxDebug?.models?.().current, null, { timeout: 60_000 });
const initial = await page.evaluate(() => ({
  t: performance.now(),
  state: window.cmuxAcpmuxDebug.models(),
  nav: performance.getEntriesByType("navigation")[0]?.domContentLoadedEventEnd,
  timeOrigin: performance.timeOrigin,
}));
console.log(
  `initial session ${initial.state.harness} ready at ${initial.t.toFixed(0)} ms after navigation (DOMContentLoaded ${initial.nav?.toFixed(0)} ms), wall ${Date.now() - loadStart} ms`,
);

initial.frames = await page.evaluate(() => window.__benchFrames.slice());
for (const q of stagesOf(initial.frames))
  console.log(
    `    ${q.method.padEnd(28)} sent +${q.sent} replied +${q.replied} (${q.rtt} ms)${q.error ? " " + q.error : ""}`,
  );
const firstFrame = initial.frames[0]?.t;
console.log(
  `    first frame at ${firstFrame?.toFixed(0)} ms; notifications: ${initial.frames
    .filter((f) => f.dir === "in" && f.method)
    .map((f) => `${f.method}@${f.t.toFixed(0)}`)
    .slice(0, 30)
    .join(" ")}`,
);

// One switch: the pick, then a frame loop until the new harness's model chip has painted.
async function switchTo(harness) {
  return page.evaluate(
    async ({ harness, prompt }) => {
      const debug = window.cmuxAcpmuxDebug;
      const frames = window.__benchFrames;
      const from = debug.models().harness;
      const fromSession = debug.chatState().sessionId;
      const mark = frames.length;
      const t0 = performance.now();
      const marks = { t0 };
      let done;
      const finished = new Promise((resolve) => (done = resolve));
      const chipText = () => document.querySelector(".acpmux-chips")?.textContent ?? "";
      const chipsBefore = chipText();
      const tick = () => {
        const now = performance.now();
        const state = debug.chatState();
        const models = debug.models();
        if (marks.sessionChanged === undefined && state.sessionId && state.sessionId !== fromSession)
          marks.sessionChanged = now;
        if (marks.harnessShown === undefined && state.harness === harness) marks.harnessShown = now;
        if (marks.chipsChanged === undefined && chipText() !== chipsBefore) marks.chipsChanged = now;
        if (
          marks.composerReady === undefined &&
          models.harness === harness &&
          models.current &&
          state.sessionId !== fromSession
        ) {
          marks.composerReady = now;
          marks.model = models.current;
          done();
          return;
        }
        if (now - t0 > 90_000) {
          marks.timeout = true;
          done();
          return;
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      const call = debug.newChat(harness).then(
        () => (marks.newChatResolved = performance.now()),
        (e) => (marks.error = String(e)),
      );
      await finished;
      await call;
      if (prompt && !marks.timeout) {
        const tp = performance.now();
        marks.promptAt = tp;
        void debug.sendPrompt(prompt);
        await new Promise((resolve) => {
          const watch = () => {
            const s = debug.chatState();
            if (s.lastAssistant?.text) {
              marks.firstToken = performance.now();
              return resolve();
            }
            if (performance.now() - tp > 120_000) return resolve();
            requestAnimationFrame(watch);
          };
          requestAnimationFrame(watch);
        });
        await new Promise((resolve) => {
          const wait = () =>
            debug.chatState().isWorking && performance.now() - tp < 180_000 ? setTimeout(wait, 50) : resolve();
          wait();
        });
        marks.turnEnd = performance.now();
      }
      const window_ = frames.slice(mark).map((f) => ({ ...f, t: f.t - t0 }));
      return {
        from,
        harness,
        wallT0: performance.timeOrigin + t0,
        marks: Object.fromEntries(Object.entries(marks).map(([k, v]) => [k, typeof v === "number" ? v - t0 : v])),
        frames: window_,
      };
    },
    { harness, prompt },
  );
}

// The JSON-RPC request each stage maps to, with its round trip.
function stagesOf(frames) {
  const outById = new Map();
  const rows = [];
  for (const f of frames) {
    if (f.dir === "out" && f.method && f.id !== null) outById.set(String(f.id), f);
    if (f.dir === "in" && f.id !== null && !f.method && outById.has(String(f.id))) {
      const req = outById.get(String(f.id));
      rows.push({
        method: req.method,
        sent: +req.t.toFixed(1),
        replied: +f.t.toFixed(1),
        rtt: +(f.t - req.t).toFixed(1),
        bytes: f.bytes,
        error: f.error,
      });
    }
  }
  return rows;
}

const results = [];
const seen = new Set();
for (const harness of sequence) {
  const r = await switchTo(harness);
  r.kind = seen.has(harness) ? "repeat" : "first";
  seen.add(harness);
  r.requests = stagesOf(r.frames);
  const notes = r.frames
    .filter((f) => f.dir === "in" && f.method)
    .reduce((acc, f) => ((acc[f.method] = (acc[f.method] ?? 0) + 1), acc), {});
  r.notifications = notes;
  delete r.frames;
  results.push(r);
  const m = r.marks;
  console.log(
    `${r.from} -> ${harness} (${r.kind}): composerReady ${m.composerReady?.toFixed(0)} ms, harnessShown ${m.harnessShown?.toFixed(0)}, sessionChanged ${m.sessionChanged?.toFixed(0)}, chipsChanged ${m.chipsChanged?.toFixed(0)}` +
      (m.firstToken ? `, first token ${(m.firstToken - m.promptAt).toFixed(0)} ms after send` : "") +
      (m.error ? ` ERROR ${m.error}` : ""),
  );
  for (const q of r.requests)
    console.log(
      `    ${q.method.padEnd(28)} sent +${q.sent} replied +${q.replied} (${q.rtt} ms)${q.error ? " " + q.error : ""}`,
    );
  await page.waitForTimeout(settleMs);
}
if (out)
  fs.writeFileSync(out, JSON.stringify({ url: url.replace(/token=[^&]+/, "token=…"), initial, results }, null, 2));
await browser.close();
