// l10n-allow-file: benchmark output, not shipped UI.
// host-line-shift.bench.ts under duress: the transcript is every row chat-sim --long 1000 drew (DURESS_ROWS json),
// a chunk streams into the last row every 4 ms, and each link state is swapped in during the stream; the shift is the
// largest move of the last 20 rows or the composer across the swap, read in one synchronous block (so the stream
// cannot move them in between), sampled 30 times per state.
/// <reference types="bun" />
import { readFileSync } from "node:fs";
import { createElement, Fragment, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium } from "./browsers";
import * as Host from "../src/agent-session/acpmux/HostError";
import { RECONNECT_LINE_AFTER_MS } from "../src/agent-session/acpmux/hostRetry";

const css = readFileSync(new URL("../src/agent-session/acpmux/styles.css", import.meta.url), "utf8");
const rows: string[] = JSON.parse(readFileSync(process.env.DURESS_ROWS!, "utf8"));
const LONG = RECONNECT_LINE_AFTER_MS + 2_000;
const noop = () => undefined;
const Slot: (props: { children?: ReactNode }) => ReactNode =
  (Host as { HostLineSlot?: (props: { children?: ReactNode }) => ReactNode }).HostLineSlot ??
  (({ children }) => createElement(Fragment, null, children));
const H = Host as any;
const states: Record<string, ReactNode> = {
  connected: createElement(H.HostRecoveringLine, {}),
  "reconnecting under 10 s": createElement(H.HostRecoveringLine, {
    relinkingSince: 0,
    now: RECONNECT_LINE_AFTER_MS - 1,
  }),
  "reconnecting past 10 s": createElement(H.HostRecoveringLine, { relinkingSince: 0, now: LONG }),
  restoring: createElement(H.HostRecoveringLine, { restoring: { waitedMs: LONG, at: 0 }, now: 0 }),
  "waiting for the service": createElement(H.HostWaitingLine, { since: 0, now: 60_000, onRestart: noop }),
  "failed, self-retrying": createElement(H.HostUnavailableLine, { message: "Can't connect." }),
  "failed, Retry": createElement(H.HostUnavailableLine, {
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
  let appended = 0;
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
  appended = n;
  return { states: out, chunks: appended, rows: document.querySelectorAll("[data-row]").length };
}, markup);
await browser.close();
const max = Math.max(...Object.values(result.states));
console.log(`HOST-LINE-SHIFT-DURESS ${JSON.stringify({ max_px: max, ...result })}`);
