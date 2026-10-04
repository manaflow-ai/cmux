// Measures one real streamed turn in the agent pane against a dev slot's acpmux daemon.
//
//   node webviews/bench/stream/measure-live.mjs --url "<dev-slot pane url>" --harness claude \
//     --engine chromium --out /tmp/out [--cwd DIR] [--prompt TEXT] [--shots DIR]
//
// Headless only. Writes <out>/<harness>-<engine>.json: the raw instrument arrays (instrument.js),
// the per-delta wire log, the pane's perf stats, and a timed fixture of the turn's agent events
// (<out>/<harness>-fixture.json) that bench/stream replays with the recorded timing.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, webkit } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(
  process.argv
    .slice(2)
    .join(" ")
    .split(/\s--/)
    .map((part) => part.replace(/^--/, ""))
    .filter(Boolean)
    .map((part) => {
      const space = part.indexOf(" ");
      return space < 0 ? [part, "1"] : [part.slice(0, space), part.slice(space + 1).trim()];
    }),
);
const engine = args.engine ?? "chromium";
// --replay FIXTURE: the production pane in mock mode replaying fixtures/FIXTURE-turn.json with its
// recorded timing (pane.html), against --origin (the dev slot's Vite origin).
const replay = args.replay;
const harness = replay ? `${replay}-replay${args.speed ? `-x${args.speed}` : ""}` : (args.harness ?? "claude");
if (replay)
  args.url = `${args.origin ?? "http://127.0.0.1:4188"}/bench/stream/pane.html?mock&fixture=${replay}&speed=${args.speed ?? 1}${args.limit ? `&limit=${args.limit}` : ""}`;
const out = args.out ?? "/tmp/acp-stream";
const shots = args.shots;
const prompt =
  args.prompt ??
  "Without using any tools or reading any files, write a long technical explainer (about 2,000 words) on how B-tree indexes work in databases. Use Markdown with ## headings, several paragraphs, a bulleted list, one comparison table with at least 5 rows and 4 columns, and three fenced code blocks (TypeScript, Python and Rust, each 20 to 40 lines). Answer directly in one message.";
fs.mkdirSync(out, { recursive: true });
if (shots) fs.mkdirSync(shots, { recursive: true });

const browser = await (engine === "webkit" ? webkit : chromium).launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 900 }, deviceScaleFactor: 2 });
await page.addInitScript({ path: path.join(here, "instrument.js") });
const frames = [];
page.on("websocket", (socket) => {
  socket.on("framereceived", (frame) => frames.push([Date.now(), String(frame.payload).length]));
});
page.on("pageerror", (error) => console.error("pageerror", error.message));
await page.goto(args.url);
await page.waitForFunction(() => window.cmuxAcpmuxDebug && window.cmuxAcpmuxActions?.["chat.send"], null, {
  timeout: 30_000,
});
await page.evaluate(() => window.cmuxAcpmuxDebug.perfStats());
if (!replay) {
  const created = await page.evaluate(
    ([h, cwd]) => window.cmuxAcpmuxDebug.newChat(h, cwd || undefined),
    [harness, args.cwd ?? ""],
  );
  console.error("session", created);
}
await page.waitForTimeout(1500);
const cdp = engine === "chromium" ? await page.context().newCDPSession(page) : undefined;
if (cdp) await cdp.send("Performance.enable");
const metric = async () =>
  cdp ? Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((m) => [m.name, m.value])) : {};
const before = await metric();
const startedAt = Date.now();
await page.evaluate(() => {
  window.__stream.phase = "pinned";
});
const sent = await page.evaluate((text) => window.cmuxAcpmuxDebug.sendPrompt(text), prompt);
console.error("sent", sent);

// Pinned for the first ~40% of the answer's chunks, then scrolled up, until the turn ends.
let scrolled = false;
let shot = 0;
const deadline = Date.now() + 8 * 60_000;
while (Date.now() < deadline) {
  const state = await page.evaluate(() => ({
    working: window.cmuxAcpmuxDebug.chatState().isWorking,
    chunks: window.__stream.ws.filter((entry) => entry[2] === "agent_message_chunk").length,
    code: document.querySelectorAll(".acpmux-row.acpmux-assistant diffs-container").length,
  }));
  if (shots && state.chunks > 0 && shot < 40 && !scrolled) {
    await page.screenshot({
      path: path.join(shots, `acp-stream-${harness}-${engine}-${String(shot).padStart(2, "0")}.png`),
    });
    shot += 1;
  }
  if (!scrolled && state.chunks > (harness.startsWith("codex") ? 400 : 300) && state.code >= 2) {
    scrolled = await page.evaluate(() => window.__streamScrollUp(500));
    console.error("scrolled up", scrolled, "at chunk", state.chunks);
  }
  if (!state.working && state.chunks > 0) break;
  await page.waitForTimeout(250);
}
const endedAt = Date.now();
const after = await metric();
const cpu = Object.fromEntries(
  [
    "TaskDuration",
    "ScriptDuration",
    "LayoutDuration",
    "RecalcStyleDuration",
    "LayoutCount",
    "RecalcStyleCount",
    "Nodes",
  ]
    .filter((key) => key in after)
    .map((key) => [
      key,
      Math.round((after[key] - (key === "Nodes" ? 0 : before[key])) * 1000) /
        (key.endsWith("Count") || key === "Nodes" ? 1000 : 1),
    ]),
);
await page.waitForTimeout(500);
const result = await page.evaluate(() => {
  const m = window.__stream;
  return {
    ws: m.ws,
    frames: m.frames,
    paints: m.paints,
    blocks: m.blocks,
    edge: m.edge,
    pin: m.pin,
    anchor: m.anchor,
    code: m.code,
    shifts: m.shifts,
    longtasks: m.longtasks,
    perf: window.cmuxAcpmuxDebug.perfStats({ raw: true }),
    log: window.cmuxAcpmuxDebug.acpLog(),
    rows: window.cmuxAcpmuxDebug.chatState(),
  };
});
// The agent text events of this turn, timed from the first, for the bench replay.
const updates = replay ? [] : await page.evaluate(() => window.__stream.updates);
const t0 = updates[0]?.[0] ?? 0;
if (!replay)
  fs.writeFileSync(
    path.join(out, `${harness}-turn.json`),
    JSON.stringify({
      harness,
      steps: updates.map(([at, update]) => [Math.round((at - t0) * 100) / 100, update.content.text]),
    }),
  );
delete result.log;
fs.writeFileSync(
  path.join(out, `${harness}-${engine}.json`),
  JSON.stringify({ harness, engine, startedAt, endedAt, cpu, playwrightFrames: frames, ...result }),
);
console.error("wrote", path.join(out, `${harness}-${engine}.json`), "updates", updates.length);
await browser.close();
