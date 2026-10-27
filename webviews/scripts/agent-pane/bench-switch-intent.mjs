// Harness switch as an intent, against a live dev slot (dev-slot.sh), in headless Chromium or
// WebKit. For each pick it reports, on the page clock:
//   paint    the first animation frame after the pick, and the header it finds in the DOM (the
//            frame paints what the DOM holds at its animation-frame callbacks);
//   ready    the new session is attached (chatState().sessionId is set and new);
//   sent     the prompt typed right after the pick goes out as session/prompt (WebSocket frame);
//   reply    the first reply text of that prompt (with --prompt only).
// A pick goes through the same action the picker's harness row runs (chat.new with a harness).
//
//   node scripts/agent-pane/bench-switch-intent.mjs --url "<agent pane URL>" \
//     [--engine chromium|webkit] [--sequence codex,claude-sr,codex] [--prompt "Reply with exactly: ok"] [--out FILE]
//
// With PERF_RESULT_DIR set it also writes, per harness, each mark of the first and the repeat picks
// as result-v1 (story webviews-switch-intent or webviews-switch-intent-webkit,
// web.switch_intent.<harness>.<first|repeat>.<mark>, and .timed_out for the picks that hit the limit).
import fs from "node:fs";
import { chromium, webkit } from "playwright";
import { recordPerfResults } from "../perf-result.mjs";
import { switchIntentPerfSeries } from "./bench-perf-series.mjs";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const url = arg("url");
if (!url) throw new Error("--url is required (dev-slot.sh url N)");
const engine = arg("engine", "chromium");
const sequence = arg("sequence", "codex,claude-sr,codex,claude-sr").split(",");
const prompt = arg("prompt");
const out = arg("out");
/// How long one pick waits for its marks before it gives up (the reply wait runs longer, below).
const PICK_LIMIT_MS = 120_000;

// Before any pane script: every outgoing JSON-RPC method with its page time.
function instrument() {
  const sent = [];
  window.__benchSent = sent;
  const Native = window.WebSocket;
  window.WebSocket = class extends Native {
    send(data) {
      try {
        const message = JSON.parse(String(data));
        sent.push({ t: performance.now(), method: message.method ?? null, sessionId: message.params?.sessionId });
      } catch {
        // not JSON-RPC
      }
      return super.send(data);
    }
  };
}

const browser = await (engine === "webkit" ? webkit : chromium).launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
await page.addInitScript(instrument);
await page.goto(url.includes("&new") ? url : `${url}&new`);
await page.waitForFunction(() => window.cmuxAcpmuxDebug?.models?.().current, null, { timeout: 90_000 });

async function pick(harness) {
  return page.evaluate(
    async ({ harness, prompt, limitMs }) => {
      const debug = window.cmuxAcpmuxDebug;
      const title = () => document.querySelector(".acpmux-title")?.textContent ?? "";
      const from = debug.chatState().sessionId;
      const mark = window.__benchSent.length;
      const t0 = performance.now();
      const switching = debug.newChat(harness);
      const marks = {};
      await new Promise((resolve) =>
        requestAnimationFrame((frame) => {
          marks.paint = frame - t0;
          marks.paintedTitle = title();
          resolve();
        }),
      );
      if (prompt) {
        const tp = performance.now();
        marks.promptAt = tp - t0;
        void debug.sendPrompt(prompt);
      }
      await new Promise((resolve) => {
        const watch = () => {
          const state = debug.chatState();
          if (marks.ready === undefined && state.sessionId && state.sessionId !== from)
            marks.ready = performance.now() - t0;
          const out = window.__benchSent.slice(mark).find((entry) => entry.method === "session/prompt");
          if (prompt && marks.sent === undefined && out) marks.sent = out.t - t0;
          if (prompt && marks.reply === undefined && state.lastAssistant?.text) marks.reply = performance.now() - t0;
          const done = marks.ready !== undefined && (!prompt || marks.reply !== undefined);
          if (done) return resolve();
          if (performance.now() - t0 > limitMs) {
            marks.timedOut = true;
            return resolve();
          }
          requestAnimationFrame(watch);
        };
        requestAnimationFrame(watch);
      });
      await switching;
      if (prompt) {
        const wait = (resolve) =>
          debug.chatState().isWorking && performance.now() - t0 < 180_000
            ? setTimeout(() => wait(resolve), 50)
            : resolve();
        await new Promise(wait);
      }
      marks.harness = debug.chatState().harness;
      return marks;
    },
    { harness, prompt, limitMs: PICK_LIMIT_MS },
  );
}

const results = [];
const seen = new Set();
for (const harness of sequence) {
  const kind = seen.has(harness) ? "repeat" : "first";
  seen.add(harness);
  const marks = await pick(harness);
  // `harness` is what the pane reports after the pick; `picked` is the one asked for, which names the
  // series (a pick that failed to switch still belongs to the harness it asked for).
  results.push({ harness, kind, ...marks, picked: harness });
  const ms = (value) => (value === undefined ? "-" : `${value.toFixed(1)} ms`);
  console.log(
    `${engine} -> ${harness} (${kind}): paint ${ms(marks.paint)} ready ${ms(marks.ready)}` +
      (prompt ? ` sent ${ms(marks.sent)} reply ${ms(marks.reply)}` : "") +
      ` [${marks.paintedTitle}]`,
  );
  await page.waitForTimeout(1000);
}
// The report and the cleanup first, so a refused result-v1 write still leaves the --out file.
if (out) fs.writeFileSync(out, JSON.stringify({ engine, results }, null, 2));
await browser.close();
recordPerfResults({
  story: engine === "webkit" ? "webviews-switch-intent-webkit" : "webviews-switch-intent",
  engine,
  series: switchIntentPerfSeries(results, { prompted: Boolean(prompt), limitMs: PICK_LIMIT_MS }),
});
