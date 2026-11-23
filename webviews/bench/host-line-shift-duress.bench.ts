// l10n-allow-file: benchmark output, not shipped UI.
// host-line-shift.bench.ts under duress (Leo, 2026-11-22: "always. testing under duress. you should also be able to
// simulate duress "offline""): the transcript is the rows chat-sim drew for a long run (--long 1000, tiled to the 4,659
// rows it draws) or for a recorded chat (DURESS_REPLAY=fixture.ndjson), a chunk streams into the last row every 4 ms,
// and each link state is swapped in mid-stream. The shift is the largest move of the last 20 rows or the composer
// across the swap, read in one synchronous block (so the stream cannot move them in between), 30 samples per state.
// For a busy machine, load it yourself while it runs (for example one `yes >/dev/null` per core) and say so.
//   bun bench/host-line-shift-duress.bench.ts   ->  HOST-LINE-SHIFT-DURESS {"max_px":0,"states":{…},"rows":4660,…}
//   DURESS_REPLAY=test/fixtures/chat-sim/replay-lane-session.ndjson bun bench/host-line-shift-duress.bench.ts
/// <reference types="bun" />
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createElement, Fragment, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium } from "./browsers";
import * as Host from "../src/agent-session/acpmux/HostError";

const css = readFileSync(new URL("../src/agent-session/acpmux/styles.css", import.meta.url), "utf8");
/** Every row chat-sim drew, in first-drawn order, each at its last text. */
function simRows(): string[] {
  const trace = join(mkdtempSync(join(tmpdir(), "host-line-duress-")), "trace.jsonl");
  const source = process.env.DURESS_REPLAY ? ["--replay", process.env.DURESS_REPLAY] : ["--long", "1000"];
  Bun.spawnSync(["bun", new URL("../scripts/chat-sim.ts", import.meta.url).pathname, ...source, "--trace", trace]);
  const text = new Map<string, string>();
  for (const line of readFileSync(trace, "utf8").split("\n")) {
    if (!line) continue;
    for (const row of (JSON.parse(line).rows ?? []) as {
      id: string;
      kind: string;
      text?: string;
    }[])
      text.set(row.id, (row.text || row.kind).slice(0, 400));
  }
  const drawn = [...text.values()];
  if (process.env.DURESS_REPLAY) return drawn;
  return Array.from({ length: 4_659 }, (_, index) => drawn[index % drawn.length]!);
}
const rows = simRows();
const noop = () => undefined;
const Slot: (props: { children?: ReactNode }) => ReactNode =
  (Host as { HostLineSlot?: (props: { children?: ReactNode }) => ReactNode }).HostLineSlot ??
  (({ children }) => createElement(Fragment, null, children));
const states: Record<string, ReactNode> = {
  // Transient link states (connecting, reconnecting, restoring) draw nothing, so "connected" stands for them all.
  connected: null,
  "waiting for the service": createElement(Host.HostWaitingLine, {
    since: 0,
    now: 60_000,
    onRestart: noop,
  }),
  "failed, self-retrying": createElement(Host.HostUnavailableLine, {
    message: "Can't connect.",
  }),
  "failed, Retry": createElement(Host.HostUnavailableLine, {
    message: "Update cmux.",
    selfRetrying: false,
    onRetry: noop,
  }),
};
const markup = Object.fromEntries(
  Object.entries(states).map(([name, line]) => [name, renderToStaticMarkup(createElement(Slot, null, line))]),
);
const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);
const page = `<!doctype html><meta charset=utf-8><style>${css}
html,body{margin:0;font:13px/1.4 system-ui}
.pane{display:flex;flex-direction:column;width:640px;height:520px}
.transcript{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end;padding:0 18px}
.transcript p{margin:0 0 10px}
.acpmux-composer{height:56px;margin:0 18px 12px;border:1px solid #888;border-radius:12px}
</style><div class=pane><div class=transcript>${rows.map((t) => `<p data-row>${esc(t)}</p>`).join("")}<p data-row id=live>streaming</p></div><div class="acpmux-dock"><div id=hostline style="display:contents">${markup.connected}</div><div class="acpmux-composer"></div></div></div>`;

const browser = await chromium.launch();
const view = await (await browser.newContext({ viewport: { width: 700, height: 560 } })).newPage();
await view.setContent(page);
const result = await view.evaluate(async (markup: Record<string, string>) => {
  const live = document.getElementById("live")!;
  const slot = document.getElementById("hostline")!;
  let n = 0;
  const words = "the agent streams another chunk of its reply while the link drops ".split(" ");
  const timer = setInterval(() => {
    live.textContent += " " + words[n++ % words.length];
    if (live.textContent!.length > 600) live.textContent = "streaming";
  }, 4);
  const watched = () =>
    [...document.querySelectorAll("[data-row]")].slice(-20).concat([document.querySelector(".acpmux-composer")!]);
  const read = () => watched().map((node) => node.getBoundingClientRect().top);
  const out: Record<string, number> = {};
  for (const name of Object.keys(markup)) {
    let worst = 0;
    for (let i = 0; i < 30; i += 1) {
      await new Promise((r) => setTimeout(r, 50));
      const before = read();
      slot.innerHTML = markup[name]!;
      const after = read();
      worst = Math.max(worst, ...after.map((top, k) => Math.abs(top - before[k]!)));
      slot.innerHTML = markup.connected!;
    }
    out[name] = Math.round(worst * 100) / 100;
  }
  clearInterval(timer);
  return {
    states: out,
    chunks: n,
    rows: document.querySelectorAll("[data-row]").length,
  };
}, markup);
await browser.close();
const max = Math.max(...Object.values(result.states));
console.log(`HOST-LINE-SHIFT-DURESS ${JSON.stringify({ max_px: max, ...result })}`);
