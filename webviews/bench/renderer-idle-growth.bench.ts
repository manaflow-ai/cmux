// l10n-allow-file: bench output, not shipped UI.
// RFD 0062: what a web renderer the app keeps open grows by while the person does nothing (a Mac measured the
// renderer group at +27 MB/min phys_footprint; the bound is 1 MB/min an instance after a 90 s settle). Each page the
// app holds at rest runs production-built in its own headless Chrome against stand-ins (no daemon, no app):
//   chat     the agent pane with one open chat (300 finished turns, 200 other chats listed) on a stand-in acpmux;
//   newtab   the agent pane as a New Tab page on the same stand-in;
//   home     the Home page (home-channels, `?mock`);
//   sidebar  a sidebar chat history block (sidebar-chats, `?mock`).
// Each loads, settles SETTLE_MS (90 s), then samples every SAMPLE_MS (30 s) for SAMPLES (14, 7 min): CDP
// Performance.getMetrics (JS heap, nodes, listeners, documents, layouts, style recalcs), the renderer process's PSS
// (/proc), and at settle, halfway and at the end a forced GC and a heap snapshot, whose three-snapshot diff names what
// piled up by constructor and by holder (heapProbe.ts). It prints a per-page table of the slopes per minute.
//   bun bench/renderer-idle-growth.bench.ts [chat,newtab,home,sidebar]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { chromium, webkit } from "./browsers";
import type { Browser, CDPSession } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { newestPage } from "./daemonPage";
import { diff, takeSnapshot, type Snapshot } from "./heapProbe";

const PAGES = (process.argv[2] ?? "chat,newtab,home,sidebar").split(",").filter(Boolean);
const SETTLE_MS = Number(process.env.SETTLE_MS ?? 90_000);
const SAMPLE_MS = Number(process.env.SAMPLE_MS ?? 30_000);
const SAMPLES = Number(process.env.SAMPLES ?? 14);
const OUT_JSON = process.env.OUT_JSON;
const webviews = path.resolve(import.meta.dir, "..");

const A = PAPERCUT_CHAT;
const chat = papercutEvents({ turns: 300, running: false });
const others = Array.from({ length: 200 }, (_, index) => ({
  ...chat.session,
  sessionId: `0190a000-0000-7000-8000-${(0x100000 + index).toString(16).padStart(12, "0")}`,
  title: `Other chat ${index + 1}`,
}));
const sessions = [chat.session, ...others];
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const lastSeq = chat.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions };
    case "_acpmux/attach": {
      if (params.sessionId !== A) return { session: others[0], lastSeq: 0, events: [], hasMore: false };
      const { page, hasMore } = newestPage(chat.events, {
        limit: Number(params.limit ?? 400),
        maxBytes: params.maxBytes,
      });
      return { session: chat.session, lastSeq, events: page, hasMore };
    }
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq };
    default:
      return null;
  }
};

type Sample = {
  t: number;
  heapMb: number;
  nodes: number;
  listeners: number;
  documents: number;
  layouts: number;
  recalcs: number;
  pssMb: number | null;
};

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of [...releases].reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));

function slopePerMin(points: { t: number; y: number }[]): number {
  const n = points.length;
  const mx = points.reduce((s, p) => s + p.t, 0) / n;
  const my = points.reduce((s, p) => s + p.y, 0) / n;
  let num = 0;
  let den = 0;
  for (const p of points) {
    num += (p.t - mx) * (p.y - my);
    den += (p.t - mx) ** 2;
  }
  return den === 0 ? 0 : (num / den) * 60_000;
}

function pssMb(pid: number | undefined): number | null {
  if (!pid) return null;
  try {
    const text = fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8");
    // USS (private pages): PSS moves when a sibling process that shares pages exits, this does not.
    const field = (key: string) => Number(new RegExp(`^${key}:\\s+(\\d+)`, "m").exec(text)?.[1]);
    const kb = field("Private_Clean") + field("Private_Dirty");
    return Number.isFinite(kb) ? kb / 1024 : null;
  } catch {
    return null;
  }
}

async function rendererPid(browser: Browser, before: Set<number>): Promise<number | undefined> {
  const session = await browser.newBrowserCDPSession();
  const info = (await session.send("SystemInfo.getProcessInfo")) as { processInfo: { type: string; id: number }[] };
  // The page's renderer is the biggest one (a spare renderer Chrome keeps warm holds about nothing).
  const renderers = info.processInfo.filter((p) => p.type === "renderer" && !before.has(p.id));
  return renderers.sort((a, b) => (pssMb(b.id) ?? 0) - (pssMb(a.id) ?? 0))[0]?.id;
}

async function metrics(cdp: CDPSession, t: number, pid: number | undefined): Promise<Sample> {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  const m = Object.fromEntries(metrics.map((x) => [x.name, x.value]));
  return {
    t,
    heapMb: (m.JSHeapUsedSize ?? 0) / 1048576,
    nodes: m.Nodes ?? 0,
    listeners: m.JSEventListeners ?? 0,
    documents: m.Documents ?? 0,
    layouts: m.LayoutCount ?? 0,
    recalcs: m.RecalcStyleCount ?? 0,
    pssMb: pssMb(pid),
  };
}

async function gcMetrics(cdp: CDPSession, t: number, pid: number | undefined): Promise<Sample> {
  await cdp.send("HeapProfiler.collectGarbage");
  await cdp.send("HeapProfiler.collectGarbage");
  return metrics(cdp, t, pid);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

try {
  const sockets = new Set<{ send(data: string): void }>();
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open(ws) {
        sockets.add(ws);
      },
      close(ws) {
        sockets.delete(ws);
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  releases.push(() => daemon.stop(true));
  // TRAFFIC=n: the stand-in acpmux sends n changes a second for other chats (a newer `updatedAt`, as running agents'
  // chats do) and the open chat's unchanged presence, as a real daemon does while the person does nothing.
  const TRAFFIC = Number(process.env.TRAFFIC ?? 0);
  if (TRAFFIC > 0) {
    let tick = 0;
    const timer = setInterval(() => {
      const session = others[tick % others.length]!;
      const send = (method: string, params: unknown) => {
        const text = JSON.stringify({ jsonrpc: "2.0", method, params });
        for (const socket of sockets) socket.send(text);
      };
      send("_acpmux/session_changed", {
        kind: "updated",
        session: { ...session, updatedAt: (Number(session.updatedAt) || 0) + 1000 * ++tick },
      });
      send("_acpmux/presence", { sessionId: A, viewers: [] });
    }, 1000 / TRAFFIC);
    releases.push(() => clearInterval(timer));
  }

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "renderer-idle-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const paneOut = path.join(out, "pane");
  const pagesOut = path.join(out, "pages");
  if (PAGES.some((p) => p === "chat" || p === "newtab")) {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: paneOut, emptyOutDir: true },
      logLevel: "error",
    });
  }
  const pageIds = PAGES.map((p) => (p === "home" ? "home-channels" : p === "sidebar" ? "sidebar-chats" : "")).filter(
    Boolean,
  );
  if (pageIds.length) {
    fs.mkdirSync(pagesOut, { recursive: true });
    const built = spawnSync("bun", ["scripts/pages/bundle.mjs", pagesOut, ...pageIds], {
      cwd: webviews,
      stdio: ["ignore", "ignore", "inherit"],
    });
    if (built.status !== 0) throw new Error("pages bundle failed");
    // As scripts/cmux-next/build-pages-web.sh writes each page's index.html.
    for (const id of pageIds) {
      const dir = path.join(pagesOut, id);
      const preloads = fs.existsSync(path.join(dir, "preloads.html"))
        ? fs.readFileSync(path.join(dir, "preloads.html"), "utf8")
        : "";
      const css = fs.existsSync(path.join(dir, "app.css")) ? fs.readFileSync(path.join(dir, "app.css"), "utf8") : "";
      fs.writeFileSync(
        path.join(dir, "index.html"),
        `<!doctype html>\n<html lang="en" data-cmux-page="${id}">\n<head>\n<meta charset="utf-8" />\n` +
          `<meta name="viewport" content="width=device-width, initial-scale=1" />\n${preloads}\n` +
          `<link rel="stylesheet" href="../__shared/page-base.css" />\n<style>\n${css}\n</style>\n</head>\n<body>\n` +
          `<main id="root"></main>\n<script type="module">\nimport "./app.js";\n</script>\n</body>\n</html>\n`,
      );
    }
  }
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      let pathname = decodeURIComponent(new URL(request.url).pathname);
      if (pathname.endsWith("/")) pathname += "index.html";
      // The pages at /<page>/ and /__shared/, the pane (whose assets are at the root) at /.
      for (const root of [pagesOut, paneOut]) {
        const file = Bun.file(path.join(root, pathname));
        if (await file.exists()) return new Response(file);
      }
      if (process.env.SHOW_ERRORS) console.log(`404 ${pathname}`);
      return new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const base = `http://127.0.0.1:${statics.port}`;
  const daemonHash = `endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux`;
  const targets: Record<string, { url: string; ready: string; width: number; height: number }> = {
    chat: { url: `${base}/#${daemonHash}&session=${A}`, ready: "Answer 300:", width: 1200, height: 800 },
    newtab: { url: `${base}/#${daemonHash}&newtab`, ready: "", width: 1200, height: 800 },
    home: { url: `${base}/home-channels/?mock`, ready: "", width: 1200, height: 800 },
    sidebar: { url: `${base}/sidebar-chats/?mock`, ready: "", width: 280, height: 600 },
  };

  const results: Record<string, unknown> = {};
  await Promise.all(
    PAGES.map(async (name) => {
      const target = targets[name];
      if (!target) throw new Error(`unknown page ${name}`);
      if (process.env.BROWSER === "webkit") return void (results[name] = await webkitRun(name, target));
      const browser = await chromium.launch({ headless: true });
      releases.push(() => browser.close());
      const before = new Set<number>();
      const context = await browser.newContext({ viewport: { width: target.width, height: target.height } });
      const page = await context.newPage();
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(String(error).slice(0, 200)));
      page.on("console", (msg) => {
        if (msg.type() === "error") errors.push(msg.text().slice(0, 200));
      });
      const cdp = await context.newCDPSession(page);
      await cdp.send("Performance.enable", { timeDomain: "timeTicks" } as never);
      await cdp.send("HeapProfiler.enable");
      await page.goto(target.url);
      if (target.ready)
        await page
          .waitForFunction((text) => document.body.textContent?.includes(text), target.ready, {
            timeout: 60_000,
            polling: 250,
          })
          .catch(async (error) => {
            console.log(`NOTREADY ${name}: ${(await page.evaluate(() => document.body.innerText)).slice(0, 300)}`);
            console.log(errors.join("\n"));
            throw error;
          });
      const pid = await rendererPid(browser, before);
      const t0 = Date.now();
      await sleep(SETTLE_MS);
      const settledGc = await gcMetrics(cdp, 0, pid);
      const snaps: Snapshot[] = [await takeSnapshot(cdp)];
      const samples: Sample[] = [];
      const start = Date.now();
      for (let i = 0; i <= SAMPLES; i++) {
        const due = start + i * SAMPLE_MS;
        if (due > Date.now()) await sleep(due - Date.now());
        samples.push(await metrics(cdp, Date.now() - start, pid));
        if (i === Math.floor(SAMPLES / 2)) snaps.push(await takeSnapshot(cdp));
      }
      const endGc = await gcMetrics(cdp, Date.now() - start, pid);
      snaps.push(await takeSnapshot(cdp));
      const minutes = endGc.t / 60_000;
      const of = (pick: (s: Sample) => number) => slopePerMin(samples.map((s) => ({ t: s.t, y: pick(s) })));
      const first = samples[0]!;
      const last = samples.at(-1)!;
      const row = {
        page: name,
        loadToSettleS: Math.round((start - t0) / 1000),
        heapMbPerMinRaw: of((s) => s.heapMb),
        heapMbPerMinGc: (endGc.heapMb - settledGc.heapMb) / minutes,
        heapGcMb: [settledGc.heapMb, endGc.heapMb],
        pssMbPerMin: first.pssMb !== null ? of((s) => s.pssMb ?? 0) : null,
        pssMb: [first.pssMb, last.pssMb],
        nodes: [settledGc.nodes, endGc.nodes],
        listeners: [settledGc.listeners, endGc.listeners],
        documents: [settledGc.documents, endGc.documents],
        layoutsPerMin: of((s) => s.layouts),
        recalcsPerMin: of((s) => s.recalcs),
        errors: errors.slice(0, 5),
        samples,
      };
      results[name] = row;
      console.log(
        `RESULT ${name}: heap raw ${row.heapMbPerMinRaw.toFixed(3)} MB/min, after GC ${row.heapMbPerMinGc.toFixed(3)} MB/min ` +
          `(${settledGc.heapMb.toFixed(2)} -> ${endGc.heapMb.toFixed(2)} MB); uss ${row.pssMbPerMin?.toFixed(2)} MB/min ` +
          `(${first.pssMb?.toFixed(1)} -> ${last.pssMb?.toFixed(1)}); nodes ${settledGc.nodes}->${endGc.nodes}; ` +
          `listeners ${settledGc.listeners}->${endGc.listeners}; documents ${settledGc.documents}->${endGc.documents}; ` +
          `layouts ${row.layoutsPerMin.toFixed(1)}/min; recalcs ${row.recalcsPerMin.toFixed(1)}/min; errors ${errors.length}`,
      );
      if (process.env.SHOW_ERRORS) console.log(`ERRORS ${name}:\n${errors.join("\n")}`);
      diff(snaps[0]!, snaps[2]!, name, snaps[1]);
      await context.close();
    }),
  );
  if (OUT_JSON) fs.writeFileSync(OUT_JSON, JSON.stringify(results, null, 1));
} finally {
  await release();
}

/// The PSS of every WebKit web process (WPEWebProcess on Linux) under this bench process (BROWSER=webkit runs one page a bench process).
function webProcessPssMb(): number {
  const children = new Map<number, number[]>();
  const comm = new Map<number, string>();
  for (const entry of fs.readdirSync("/proc")) {
    const pid = Number(entry);
    if (!Number.isInteger(pid)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const close = stat.lastIndexOf(")");
      comm.set(pid, stat.slice(stat.indexOf("(") + 1, close));
      const ppid = Number(stat.slice(close + 2).split(" ")[1]);
      children.set(ppid, [...(children.get(ppid) ?? []), pid]);
    } catch {
      // Gone.
    }
  }
  let total = 0;
  const walk = (pid: number) => {
    for (const child of children.get(pid) ?? []) {
      if (/(WebKit|WPE)WebProces/.test(comm.get(child) ?? "")) total += pssMb(child) ?? 0;
      walk(child);
    }
  };
  walk(process.pid);
  return total;
}

/// The same idle run in Playwright's WebKit (the engine the app's WKWebView runs; no CDP there): the web process's
/// PSS, and the page's own DOM and running-animation counts read in the page.
async function webkitRun(name: string, target: { url: string; ready: string; width: number; height: number }) {
  const browser = await webkit.launch({ headless: true });
  releases.push(() => browser.close());
  const page = await (await browser.newContext({ viewport: { width: target.width, height: target.height } })).newPage();
  await page.goto(target.url);
  if (target.ready)
    await page.waitForFunction((text) => document.body.textContent?.includes(text), target.ready, {
      timeout: 60_000,
      polling: 250,
    });
  await sleep(SETTLE_MS);
  const samples: { t: number; pssMb: number; nodes: number; animations: number }[] = [];
  const start = Date.now();
  for (let i = 0; i <= SAMPLES; i++) {
    const due = start + i * SAMPLE_MS;
    if (due > Date.now()) await sleep(due - Date.now());
    const inPage = await page.evaluate(() => ({
      nodes: document.getElementsByTagName("*").length,
      animations: document.getAnimations().length,
    }));
    samples.push({ t: Date.now() - start, pssMb: webProcessPssMb(), ...inPage });
  }
  const pssPerMin = slopePerMin(samples.map((s) => ({ t: s.t, y: s.pssMb })));
  console.log(
    `RESULT webkit ${name}: uss ${pssPerMin.toFixed(2)} MB/min (${samples[0]!.pssMb.toFixed(1)} -> ` +
      `${samples.at(-1)!.pssMb.toFixed(1)}); elements ${samples[0]!.nodes}->${samples.at(-1)!.nodes}; ` +
      `running animations ${samples[0]!.animations}->${samples.at(-1)!.animations}`,
  );
  await browser.close();
  return { page: name, pssPerMin, samples };
}
