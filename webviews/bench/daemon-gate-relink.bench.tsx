// l10n-allow-file: benchmark output, not shipped UI.
// How soon a shown Home Channels or Messages page asks its daemon again once the daemon is back after a restart
// (Leo, 2026-11-14: "load faster/percievably load faster / whatever it takes"). The real DaemonGate, real
// timers, in JSDOM with the page shown: ROUNDS gates at once, each on a host whose daemon is down for DOWN_MS
// (each round ±20%) and then answers. Reports, per outage, p50 and p95 of the time from the daemon answering to
// the gate's next credential load (its next ask).
//   [GATE_MODULE=../src/pages/home-channels/DaemonGate.tsx] [ROUNDS=40] [DOWNS=3000,10000] \
//     bun test ./bench/daemon-gate-relink.bench.tsx
// For the baseline, git show BASE:webviews/src/pages/home-channels/DaemonGate.tsx >
// src/pages/home-channels/DaemonGate.before.tsx and set GATE_MODULE=../src/pages/home-channels/DaemonGate.before.tsx.
import { test } from "bun:test";

import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../src/pages/shared/i18n";
import { pageError } from "../src/pages/shared/pageClient";
import type { DaemonSource } from "../src/pages/home-channels/DaemonGate";

const moduleURL = new URL(process.env.GATE_MODULE ?? "../src/pages/home-channels/DaemonGate.tsx", import.meta.url);
const ROUNDS = Number(process.env.ROUNDS ?? 40);
const DOWNS = (process.env.DOWNS ?? "3000,10000").split(",").map(Number);

const strings = createStrings({ en: { "connect.connecting": "Connecting…" } }, ["en"]);
const pct = (values: number[], share: number) =>
  [...values].sort((a, b) => a - b)[Math.min(values.length - 1, Math.floor(share * values.length))]!;

test(
  "daemon gate relink after a restart",
  async () => {
    const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
    Object.defineProperty(dom.window.document, "visibilityState", { value: "visible", configurable: true });
    Object.assign(globalThis, {
      window: dom.window,
      document: dom.window.document,
      navigator: dom.window.navigator,
      sessionStorage: dom.window.sessionStorage,
      HTMLElement: dom.window.HTMLElement,
      Node: dom.window.Node,
      Element: dom.window.Element,
    });
    const { DaemonGate } = (await import(moduleURL.href)) as typeof import("../src/pages/home-channels/DaemonGate");
    console.log(`gate module: ${moduleURL.pathname.split("/").pop()}`);
    for (const down of DOWNS) {
      const relinks: number[] = [];
      const roots = await Promise.all(
        Array.from({ length: ROUNDS }, async () => {
          const start = performance.now();
          const upAt = start + down * (0.8 + Math.random() * 0.4);
          let answered = false;
          return new Promise<() => void>((resolve) => {
            const source: DaemonSource = {
              kind: "host",
              load: () => {
                const now = performance.now();
                if (now < upAt)
                  return Promise.reject(pageError("cmux.protocol.unavailable", "Starting this build's Chief…", true));
                if (!answered) {
                  answered = true;
                  relinks.push(now - upAt);
                }
                // The daemon is back: the page has asked, which is all this bench times.
                return new Promise(() => {});
              },
            };
            const host = dom.window.document.createElement("div");
            dom.window.document.body.append(host);
            const root = createRoot(host);
            root.render(
              <DaemonGate source={source} strings={strings}>
                {() => null}
              </DaemonGate>,
            );
            resolve(() => root.unmount());
          });
        }),
      );
      const deadline = performance.now() + down * 1.2 + 12_000;
      while (relinks.length < ROUNDS && performance.now() < deadline) await new Promise((r) => setTimeout(r, 50));
      for (const unmount of roots) unmount();
      console.log(
        `gate relink after daemon up (${down} ms down, ±20%): p50 ${pct(relinks, 0.5).toFixed(0)} ms, p95 ${pct(relinks, 0.95).toFixed(0)} ms (n=${relinks.length}/${ROUNDS})`,
      );
    }
    dom.window.close();
  },
  { timeout: 300_000 },
);
