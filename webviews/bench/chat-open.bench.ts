// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Opening a chat, stage by stage: the production pane (a vite build of the pane's dev entry) joins a
// stand-in acpmux that holds a TURNS-turn chat, as test/support/papercutChat.ts does. Each round loads a
// fresh page and records, from navigation start (performance.now()):
//   attach     the stand-in answered `_acpmux/attach` (the history left the daemon);
//   firstRow   the first transcript row painted;
//   latest     the newest message ("Answer N:") painted;
//   settled    nothing moved for 400 ms after that: no long task, layout shift or DOM change.
// The stages that follow `attach` are the page's own: parse, first render and layout passes.
// Long tasks (count, total), layout-shift sum and the transcript's scroll drift after `latest` say how
// much the page still moved after the newest messages appeared.
//   bun bench/chat-open.bench.ts [rounds=7] [turns=300]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
const webviews = path.resolve(import.meta.dir, "..");
const LATEST = `Answer ${TURNS}:`;

const { events, session } = papercutEvents({ turns: TURNS, running: false });
let attachedAt = 0;
let attachBytes = 0;
const answer = (method: string): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach": {
      const result = { session, lastSeq: events.length, events, hasMore: false };
      attachBytes = JSON.stringify(result).length;
      return result;
    }
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
};

const releases: [string, () => unknown][] = [];
const release = async () => {
  for (const [, stop] of releases.reverse()) await Promise.resolve(stop()).catch(() => undefined);
};

try {
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string };
        if (message.id === undefined) return;
        const result = answer(message.method);
        if (message.method === "_acpmux/attach") attachedAt = Date.now();
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
      },
    },
  });
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-open-bench-"));
  releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({ headless: true });
  releases.push(["browser", () => browser.close()]);

  type Round = {
    attach: number;
    firstRow: number;
    latest: number;
    settled: number;
    longTasks: number;
    longMs: number;
    shift: number;
    drift: number;
  };
  const open = async (): Promise<Round> => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    await page.addInitScript((latestText) => {
      const state = { firstRow: 0, latest: 0, activity: 0, longTasks: 0, longMs: 0, shift: 0, top: -1, drift: 0 };
      (window as unknown as { __open: typeof state }).__open = state;
      const afterPaint = (done: () => void) => requestAnimationFrame(() => setTimeout(done, 0));
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          state.longTasks += 1;
          state.longMs += entry.duration;
          state.activity = Math.max(state.activity, entry.startTime + entry.duration);
        }
      }).observe({ type: "longtask", buffered: true });
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as unknown as { value: number; hadRecentInput: boolean; startTime: number }[]) {
          if (entry.hadRecentInput) continue;
          state.shift += entry.value;
          state.activity = Math.max(state.activity, entry.startTime);
        }
      }).observe({ type: "layout-shift", buffered: true });
      const tick = () => {
        const now = performance.now();
        if (!state.firstRow && document.querySelector("[data-row-id]")) afterPaint(() => (state.firstRow ||= performance.now()));
        if (!state.latest && document.body.textContent?.includes(latestText)) afterPaint(() => (state.latest ||= performance.now()));
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const top = scroller ? scroller.scrollTop + scroller.scrollHeight : -1;
        if (top !== state.top) {
          if (state.latest) state.drift += 1;
          state.top = top;
          state.activity = Math.max(state.activity, now);
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, LATEST);
    attachedAt = 0;
    const started = Date.now();
    await page.goto(url);
    await page.waitForFunction(
      () => {
        const state = (window as unknown as { __open: { latest: number; activity: number } }).__open;
        return state.latest > 0 && performance.now() - Math.max(state.latest, state.activity) > 400;
      },
      undefined,
      { timeout: 120_000, polling: 100 },
    );
    const got = await page.evaluate(() => {
      const state = (window as unknown as { __open: Record<string, number> }).__open;
      return { ...state, origin: performance.timeOrigin };
    });
    await page.close();
    const attach = attachedAt ? attachedAt - got.origin : 0;
    void started;
    return {
      attach,
      firstRow: got.firstRow!,
      latest: got.latest!,
      settled: Math.max(got.latest!, got.activity!),
      longTasks: got.longTasks!,
      longMs: got.longMs!,
      shift: got.shift!,
      drift: got.drift!,
    };
  };

  await open(); // warm the page's caches
  const rounds: Round[] = [];
  for (let round = 0; round < ROUNDS; round += 1) rounds.push(await open());
  const median = (pick: (r: Round) => number) => [...rounds.map(pick)].sort((a, b) => a - b)[Math.floor(rounds.length / 2)]!;
  console.log(`chat-open: ${TURNS} turns, ${events.length} events, attach payload ${(attachBytes / 1024).toFixed(0)} KiB, median of ${ROUNDS}`);
  console.log("attach ms | firstRow ms | latest ms | settled ms | long tasks | long ms | layout shift | scroll moves after latest");
  console.log(
    [
      median((r) => r.attach).toFixed(0),
      median((r) => r.firstRow).toFixed(0),
      median((r) => r.latest).toFixed(0),
      median((r) => r.settled).toFixed(0),
      median((r) => r.longTasks).toFixed(0),
      median((r) => r.longMs).toFixed(0),
      median((r) => r.shift).toFixed(4),
      median((r) => r.drift).toFixed(0),
    ].join(" | "),
  );
} finally {
  await release();
}
