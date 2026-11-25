// l10n-allow-file: benchmark output, not shipped UI.
// How far the agent pane's chat rows move when its link drops and comes back: the pane's host line (HostError.tsx)
// in each of its states, drawn with the real styles.css in Chromium, and the largest move of any chat row against
// the connected state, in CSS px (Leo, 2026-11-21: "stop layout shifting"). Before the connection chip the
// "Reconnecting…" line was a row above the composer and pushed the chat up by its height; now it is out of flow
// and every state reads 0. test/support/noLayoutShift.ts is the jsdom form of the same check (the CI test).
//   HOST_LINE_SHOTS=dir (optional) saves a screenshot per state.
//   bun bench/host-line-shift.bench.ts            ->  HOST-LINE-SHIFT {"max_px":0,"states":{…}}
/// <reference types="bun" />
import { readFileSync } from "node:fs";
import { createElement, Fragment, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium } from "./browsers";
import * as Host from "../src/agent-session/acpmux/HostError";
import { RECONNECT_LINE_AFTER_MS } from "../src/agent-session/acpmux/hostRetry";

const css = readFileSync(new URL("../src/agent-session/acpmux/styles.css", import.meta.url), "utf8");
const LONG = RECONNECT_LINE_AFTER_MS + 2_000;
const noop = () => undefined;
// The slot exists from the chip's change on; before it the line was a row of the dock itself.
const Slot: (props: { children?: ReactNode }) => ReactNode =
  (Host as { HostLineSlot?: (props: { children?: ReactNode }) => ReactNode }).HostLineSlot ??
  (({ children }) => createElement(Fragment, null, children));

const states: Record<string, ReactNode> = {
  connected: createElement(Host.HostRecoveringLine, {}),
  "reconnecting under 10 s": createElement(Host.HostRecoveringLine, {
    relinkingSince: 0,
    now: RECONNECT_LINE_AFTER_MS - 1,
  }),
  "reconnecting past 10 s": createElement(Host.HostRecoveringLine, { relinkingSince: 0, now: LONG }),
  "chip: dot": createElement(Host.HostRecoveringLine, { relinkingSince: 0, now: LONG, variant: "dot" }),
  "chip: corner": createElement(Host.HostRecoveringLine, { relinkingSince: 0, now: LONG, variant: "corner" }),
  restoring: createElement(Host.HostRecoveringLine, { restoring: { waitedMs: LONG, at: 0 }, now: 0 }),
  "waiting for the service": createElement(Host.HostWaitingLine, { since: 0, now: 60_000, onRestart: noop }),
  "failed, self-retrying": createElement(Host.HostUnavailableLine, { message: "Can't connect." }),
  "failed, Retry": createElement(Host.HostUnavailableLine, {
    message: "Update cmux.",
    selfRetrying: false,
    onRetry: noop,
  }),
};

const page = (line: ReactNode) =>
  `<!doctype html><meta charset=utf-8><style>${css}
html,body{margin:0;font:13px/1.4 system-ui}
.pane{display:flex;flex-direction:column;width:640px;height:520px}
.transcript{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end;padding:0 18px}
.transcript p{margin:0 0 10px;height:28px}
.acpmux-composer{height:56px;margin:0 18px 12px;border:1px solid #888;border-radius:12px}
</style><div class=pane><div class=transcript>${[1, 2, 3, 4, 5, 6]
    .map((n) => `<p data-row=${n}>message ${n}</p>`)
    .join(
      "",
    )}</div><div class="acpmux-dock">${renderToStaticMarkup(createElement(Slot, null, line))}<div class="acpmux-composer"></div></div></div>`;

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 700, height: 560 } });
const view = await context.newPage();
const tops: Record<string, number[]> = {};
for (const [name, line] of Object.entries(states)) {
  await view.setContent(page(line));
  if (process.env.HOST_LINE_SHOTS)
    await view.screenshot({ path: `${process.env.HOST_LINE_SHOTS}/${name.replace(/\W+/g, "-")}.png` });
  tops[name] = await view.$$eval("[data-row]", (nodes) => nodes.map((node) => node.getBoundingClientRect().top));
}
await browser.close();

const base = tops.connected!;
const shift: Record<string, number> = {};
for (const [name, rows] of Object.entries(tops))
  shift[name] = Math.max(...rows.map((top, index) => Math.abs(top - base[index]!)));
const max = Math.max(...Object.values(shift));
console.log(`HOST-LINE-SHIFT ${JSON.stringify({ max_px: max, states: shift })}`);
if (max > 0) process.exitCode = 1;
