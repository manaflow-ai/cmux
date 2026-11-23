// l10n-allow-file: benchmark output, not shipped UI.
// How far the web app moves when its link changes state (Leo, 2026-11-21: "stop layout shifting"): chief-web's header
// line (ChiefWeb.tsx `.chief-web__connection`) and the guest page's notice (GuestPage.tsx `.guest-live__notice`), each
// branch's markup with the real CSS in Chromium. The number is the largest move, against the live state, of the header's
// bottom edge, the last 21 transcript rows or the composer, in px; `covered` is how much of a row an overlay hides.
// Duress: WEB_SHIFT_ROWS=4659 (the rows chat-sim --long 1000 draws) and WEB_SHIFT_STREAM=1 (a chunk into the last row
// every 4 ms, 30 swaps per state); load the machine yourself and say so. Before and after at commits:
//   scripts/measure/bench-at-commits.sh bench/web-connection-shift.bench.ts SHA1 SHA2
//   bun bench/web-connection-shift.bench.ts   ->  WEB-CONNECTION-SHIFT {"chief-web":{"offline":{"shift":0,…},…},"guest":{…}}
/// <reference types="bun" />
import { readFileSync } from "node:fs";
import { createElement as h, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium } from "./browsers";
import { Spinner } from "../src/agent-session/acpmux/conversation/icons";

const css = (path: string) => readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");
const styles = [
  "ui/theme.generated.css",
  "agent-session/guest/page.css",
  "agent-session/guest/guest.css",
  "chief-web/chief-web.css",
]
  .map(css)
  .join("\n");
const count = Number(process.env.WEB_SHIFT_ROWS ?? 6);
const stream = process.env.WEB_SHIFT_STREAM === "1";
const rows = Array.from(
  { length: count },
  (_, i) => `<p data-row style="margin:0 0 10px">message ${i + 1} ${"of the chat ".repeat(1 + (i % 9))}</p>`,
).join("");

// chief-web header, each branch of ChiefWeb.tsx's <output className="chief-web__connection">.
const chief: Record<string, ReactNode> = {
  live: null,
  connecting: [h(Spinner, { size: 14, key: 1 }), h("span", { key: 2 }, "Connecting…")],
  reconnecting: [h(Spinner, { size: 14, key: 1 }), h("span", { key: 2 }, "Reconnecting…")],
  offline: [h("span", { key: 1 }, "Can't reach Chief."), h("button", { key: 2 }, "Retry")],
  expired: [h("span", { key: 1 }, "Signed out"), h("button", { key: 2 }, "Sign in again")],
  inaccessible: h("span", { role: "alert" }, "This chief isn't yours."),
};
const chiefPage = (slot: string) =>
  `<div class="chief-web"><header class="chief-web__header"><h1>Chief</h1><output class="chief-web__connection" id=slot>${slot}</output></header><main class="chief-web__transcript"><div style="flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-start;padding:0 18px">${rows}<p data-row id=live style="margin:0">streaming</p></div></main><div class="chief-web__dock"><div class="guest-composer" data-row style="height:56px"></div></div></div>`;
// guest page: GuestPage.tsx's notice, inside .guest-live__transcript.
const guest: Record<string, string> = {
  live: "",
  connecting: `<output class="guest-live__notice">Connecting…</output>`,
  reconnecting: `<output class="guest-live__notice">Reconnecting…</output>`,
  "load failed": `<div class="guest-live__notice guest-live__notice--failed" role="alert">Couldn't load. <button class="guest-live__retry">Retry</button></div>`,
};
const guestPage = (slot: string) =>
  `<div class="guest-live" style="display:flex;flex-direction:column;height:100vh"><header class="guest-live__header"><div class="guest-live__titles"><h1 class="guest-live__title">Chat</h1><p class="guest-live__owner">Shared by Alex</p></div></header><div class="guest-live__transcript"><div style="flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-start">${rows}<p data-row id=live>streaming</p></div><span id=slot style="display:contents">${slot}</span></div><div class="guest-live__dock"><div class="guest-composer" data-row style="height:56px"></div></div></div>`;

const browser = await chromium.launch();
const view = await (await browser.newContext({ viewport: { width: 390, height: 760 } })).newPage();
const result: Record<string, Record<string, { shift: number; covered: number }>> = {};
for (const [surface, page, states] of [
  [
    "chief-web",
    chiefPage,
    Object.fromEntries(
      Object.entries(chief).map(([k, v]) => [k, v ? renderToStaticMarkup(h("span", null, v)).slice(6, -7) : ""]),
    ),
  ],
  ["guest", guestPage, guest],
] as const) {
  await view.setContent(`<!doctype html><meta charset=utf-8><style>${styles}</style>${page("")}`);
  result[surface] = await view.evaluate(
    async ({ states, stream }) => {
      const slot = document.getElementById("slot")!;
      const live = document.getElementById("live")!;
      let n = 0;
      const timer = stream
        ? setInterval(() => {
            live.textContent += " chunk" + n++;
            if (live.textContent!.length > 400) live.textContent = "streaming";
          }, 4)
        : 0;
      const watched = () =>
        [...document.querySelectorAll("header, [data-row]")]
          .slice(0, 1)
          .concat([...document.querySelectorAll("[data-row]")].slice(-21));
      const out: Record<string, { shift: number; covered: number }> = {};
      for (const [name, markup] of Object.entries(states)) {
        let shift = 0,
          covered = 0;
        for (let i = 0; i < (stream ? 30 : 1); i++) {
          if (stream) await new Promise((r) => setTimeout(r, 50));
          slot.innerHTML = "";
          const before = watched().map((e) => e.getBoundingClientRect().bottom);
          slot.innerHTML = markup;
          const after = watched().map((e) => e.getBoundingClientRect());
          shift = Math.max(shift, ...after.map((r, k) => Math.abs(r.bottom - before[k]!)));
          const note = slot.querySelector(".guest-live__notice")?.getBoundingClientRect();
          if (note)
            covered = Math.max(
              covered,
              ...after.map((r) => Math.max(0, Math.min(r.bottom, note.bottom) - Math.max(r.top, note.top))),
            );
          slot.innerHTML = "";
        }
        out[name] = {
          shift: Math.round(shift * 100) / 100,
          covered: Math.round(covered * 100) / 100,
        };
      }
      clearInterval(timer);
      return out;
    },
    { states, stream },
  );
}
await browser.close();
console.log(`WEB-CONNECTION-SHIFT ${JSON.stringify(result)}`);
