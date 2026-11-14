// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// What one more open agent chat costs once every chat shares one renderer (CMUX-571, Leo 2026-11-12: "infinite
// everything feels like nothing"). The app gives its first-party page scheme one renderer per site
// (CEFSwitches.processPerSitePageSchemes, cmux#37807), so a chat's cost is no longer a process but what its document
// holds in that shared renderer. This bench opens the production pane (a vite build of the pane's dev entry) COUNTS
// times in one Chromium launched with --process-per-site, each page its own TURNS-turn chat on a stand-in acpmux,
// and at each count, after the pages settle and a forced collection on each:
//   renderers         the renderer processes of the launch (one: the pages share it, as chats do in the app);
//   renderer MB       their proportional set size (Linux /proc/PID/smaps_rollup Pss), the memory they hold;
//   MB per chat       (renderer MB at N - renderer MB at the first count) / (N - first count): one more chat's cost;
//   js heap MB        the shared renderer's JS heap after a collection on every page (CDP Runtime.getHeapUsage: one
//                     isolate serves every page of the renderer, so it is read once);
//   wakeups/s         the timer, frame and idle callbacks all pages ran over IDLE_MS of nothing (bench/stability.ts);
//   warm load         from navigation to the newest reply drawn, for every chat after the first: a chat page built
//                     in the warm shared renderer, as a released hidden chat is when it shows again.
// HIDDEN=1 hides every chat but the newest before each sample (the document turns hidden, as a chat tab that is not
// shown does in the app), so a row is what hidden chats cost; after the last count the oldest chat shows again and
// its time from shown to the newest reply drawn is printed (chat_pages_memory.reshow).
// The empty row (count 0) is the renderer holding one about:blank page of the same site, what the app's renderer
// holds with no chat open: the per-chat target is a chat page costing about nothing beside it.
//   bun bench/chat-pages-memory.bench.ts [counts=1,10,30] [turns=100]
// Linux only (it reads /proc); prints PERF_ROW lines (chat_pages_memory.*).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CDPSession, Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { takeSnapshot, type Snapshot } from "./heapProbe";
import { perfRow } from "./perfRow";
import { addStabilityProbe, measureIdle, settledAt } from "./stability";

const COUNTS = (process.argv[2] ?? "1,10,30").split(",").map(Number);
const TURNS = Number(process.argv[3] ?? 100);
const IDLE_WINDOW_MS = Number(process.env.IDLE_MS ?? 5000);
if (COUNTS.some((n) => !Number.isInteger(n) || n < 1) || !Number.isInteger(TURNS) || TURNS < 1) {
  console.error("usage: bun bench/chat-pages-memory.bench.ts [counts=1,10,30] [turns=100]");
  process.exit(2);
}
if (process.platform !== "linux") {
  console.error("chat-pages-memory: Linux only (renderer memory from /proc)");
  process.exit(2);
}
COUNTS.sort((a, b) => a - b);
const webviews = path.resolve(import.meta.dir, "..");
const FIRST_TEXT = `Answer ${TURNS}:`;
const template = papercutEvents({ turns: TURNS, running: false });
const sessionId = (index: number) =>
  index === 0 ? PAPERCUT_CHAT : `0190b000-0000-7000-8000-${(0x100000 + index).toString(16).padStart(12, "0")}`;
const total = COUNTS.at(-1)!;
const sessions = Array.from({ length: total }, (_, index) => ({
  ...template.session,
  sessionId: sessionId(index),
  title: `Chat ${index + 1}`,
}));
// Each chat's own events: the template's, re-keyed to its session.
const eventsOf = (id: string) =>
  id === PAPERCUT_CHAT
    ? template.events
    : template.events.map((event) => JSON.parse(JSON.stringify(event).replaceAll(PAPERCUT_CHAT, id)));
const chatEvents = new Map<string, ReturnType<typeof eventsOf>>();

const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions };
    case "_acpmux/attach": {
      const id = String(params.sessionId ?? PAPERCUT_CHAT);
      const session = sessions.find((s) => s.sessionId === id) ?? sessions[0]!;
      let events = chatEvents.get(id);
      if (!events) chatEvents.set(id, (events = eventsOf(id)));
      const { page, hasMore } = newestPage(events, { limit: Number(params.limit ?? 400), maxBytes: params.maxBytes });
      return { session, lastSeq: events.at(-1)?.seq ?? 0, events: page, hasMore };
    }
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: chatEvents.get(String(params.sessionId))?.at(-1)?.seq ?? 0 };
    default:
      return null;
  }
};

/// The renderer processes under `root` (a Chromium launch), by their command line.
function renderers(root: number): number[] {
  const children = new Map<number, number[]>();
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, "utf8");
      const parent = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      children.set(parent, [...(children.get(parent) ?? []), Number(entry)]);
    } catch {
      // Gone between the listing and the read.
    }
  }
  const out: number[] = [];
  const walk = (pid: number) => {
    for (const child of children.get(pid) ?? []) {
      try {
        if (fs.readFileSync(`/proc/${child}/cmdline`, "utf8").includes("--type=renderer")) out.push(child);
      } catch {
        // Gone.
      }
      walk(child);
    }
  };
  walk(root);
  return out;
}

/// A process's proportional set size in MB (shared pages split among their sharers).
function pssMB(pid: number): number {
  const rollup = fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8");
  const kb = Number(/^Pss:\s+(\d+) kB/m.exec(rollup)?.[1] ?? 0);
  return kb / 1024;
}

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
try {
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  releases.push(() => daemon.stop(true));
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-pages-memory-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
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
      if (pathname === "/empty")
        return new Response("<!doctype html><title>empty</title>", { headers: { "content-type": "text/html" } });
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const origin = `http://127.0.0.1:${statics.port}`;
  const urlFor = (index: number) =>
    `${origin}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId(index)}`;

  // One renderer per site, as the app gives cmux-page (the fork's scheme-scoped switch; for one site the same).
  const server = await chromium.launchServer({
    headless: true,
    args: ["--process-per-site", "--js-flags=--expose-gc"],
  });
  releases.push(() => server.close());
  const root = server.process().pid!;
  const browser = await chromium.connect(server.wsEndpoint());
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  await addStabilityProbe(context, { boxes: false });

  const sample = async (pages: { page: Page; cdp: CDPSession }[]) => {
    for (const { cdp } of pages) await cdp.send("HeapProfiler.collectGarbage");
    const heap = ((await pages[0]!.cdp.send("Runtime.getHeapUsage")) as { usedSize: number }).usedSize / 1048576;
    // Let the collections' freed pages go back before reading the process.
    await new Promise((resolve) => setTimeout(resolve, 1500));
    const pids = renderers(root);
    const mb = pids.reduce((sum, pid) => sum + pssMB(pid), 0);
    return { renderers: pids.length, mb, heap };
  };

  // Empty: the shared renderer with one page of the site and no chat.
  const emptyPage = await context.newPage();
  await emptyPage.goto(`${origin}/empty`);
  const emptyCdp = await context.newCDPSession(emptyPage);
  const empty = await sample([{ page: emptyPage, cdp: emptyCdp }]);
  console.log(`chat-pages-memory: ${TURNS} turns a chat; counts ${COUNTS.join(", ")}`);
  console.log("chats | renderers | renderer MB | MB per chat | js heap MB | wakeups/s (all pages)");
  console.log(`0 | ${empty.renderers} | ${empty.mb.toFixed(1)} | - | ${empty.heap.toFixed(1)} | -`);
  perfRow({ name: "chat_pages_memory.empty.renderer_mb", p50: empty.mb, p95: empty.mb, unit: "MB" });

  const pages: { page: Page; cdp: CDPSession }[] = [];
  // KINDS=1: what one more chat adds to the shared isolate's heap, by node kind and name (heap snapshot at the
  // first count and the last, the difference per chat).
  const bySize = (snapshot: Snapshot) => {
    const sizes = new Map<string, number>();
    for (let i = 0; i < snapshot.nodes.length; i += snapshot.nf) {
      const type = snapshot.nodeTypes[snapshot.nodes[i]!] ?? "?";
      const name = `${type}:${(snapshot.strings[snapshot.nodes[i + 1]!] ?? "").slice(0, 60)}`;
      sizes.set(name, (sizes.get(name) ?? 0) + snapshot.nodes[i + 3]!);
    }
    return sizes;
  };
  // A chat tab that is not shown: its document turns hidden (CEF's WasHidden). Headless Chromium keeps every page
  // visible, so the page's own view of it is set and announced as the engine would.
  const setHidden = (page: Page, hidden: boolean) =>
    page.evaluate((hide) => {
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => (hide ? "hidden" : "visible"),
      });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => hide });
      document.dispatchEvent(new Event("visibilitychange"));
    }, hidden);
  const hiddenPages = new Set<Page>();
  const warmLoads: number[] = [];
  let kindsAt: { count: number; sizes: Map<string, number> } | undefined;
  let first: { count: number; mb: number } | undefined;
  for (const count of COUNTS) {
    while (pages.length < count) {
      const index = pages.length;
      const page = await context.newPage();
      await page.goto(urlFor(index));
      const shown = await page.waitForFunction(
        (text) => (document.body.textContent?.includes(text) ? performance.now() : false),
        FIRST_TEXT,
        { timeout: 120_000, polling: "raf" },
      );
      // From navigation start to the newest reply drawn (page clock). After the first chat the renderer is warm,
      // as it is when a released hidden chat is built again (agents.hiddenChats.discard).
      if (index > 0) warmLoads.push(Number(await shown.jsonValue()));
      pages.push({ page, cdp: await context.newCDPSession(page) });
    }
    // The newest pages' own settling (read-ahead, fonts, the first paints) is not idle.
    await new Promise((resolve) => setTimeout(resolve, 3000));
    for (const { page } of pages) await settledAt(page).catch(() => undefined);
    if (process.env.HIDDEN === "1") {
      for (const { page } of pages.slice(0, -1)) {
        if (hiddenPages.has(page)) continue;
        await setHidden(page, true);
        hiddenPages.add(page);
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
    const idle = await measureIdle(
      pages.map(({ page }) => ({ page, cdp: null })),
      IDLE_WINDOW_MS,
    );
    const wakeups = idle.reduce((sum, row) => sum + row.wakeups, 0) / (IDLE_WINDOW_MS / 1000);
    const sources = idle.flatMap((row) => row.sources).slice(0, 4);
    const now = await sample(pages);
    if (process.env.KINDS === "1") {
      const sizes = bySize(await takeSnapshot(pages[0]!.cdp));
      if (kindsAt) {
        const per = count - kindsAt.count;
        const rows = [...sizes].map(([name, size]) => [name, (size - (kindsAt!.sizes.get(name) ?? 0)) / per] as const);
        const sum = rows.reduce((total, [, size]) => total + size, 0);
        console.log(`chat-pages-memory: heap snapshot ${(sum / 1048576).toFixed(1)} MB more a chat; largest:`);
        for (const [name, size] of rows.sort((a, b) => b[1] - a[1]).slice(0, 30))
          console.log(`  ${(size / 1048576).toFixed(2).padStart(7)} MB  ${name}`);
      } else kindsAt = { count, sizes };
    }
    first ??= { count, mb: now.mb };
    const perChat = count > first.count ? (now.mb - first.mb) / (count - first.count) : (now.mb - empty.mb) / count;
    console.log(
      `${count} | ${now.renderers} | ${now.mb.toFixed(1)} | ${perChat.toFixed(1)} | ${now.heap.toFixed(1)} | ${wakeups.toFixed(1)}${sources.length ? ` (${sources.join("; ")})` : ""}`,
    );
    perfRow({ name: `chat_pages_memory.n${count}.renderer_mb`, p50: now.mb, p95: now.mb, unit: "MB" });
    perfRow({ name: `chat_pages_memory.n${count}.mb_per_chat`, p50: perChat, p95: perChat, unit: "MB" });
    perfRow({ name: `chat_pages_memory.n${count}.renderers`, p50: now.renderers, p95: now.renderers, unit: "count" });
    perfRow({
      name: `chat_pages_memory.n${count}.idle_wakeups_per_s`,
      p50: wakeups,
      p95: wakeups,
      unit: "count",
      target: 0,
      floor: 1,
    });
  }
  if (process.env.PURGE === "1") {
    // What Chromium's own memory-pressure response gives back with every page kept (bench_memory.py --purge-hidden).
    await pages[0]!.cdp.send("Memory.simulatePressureNotification", { level: "critical" });
    await new Promise((resolve) => setTimeout(resolve, 3000));
    const purged = await sample(pages);
    console.log(
      `${pages.length} purged | ${purged.renderers} | ${purged.mb.toFixed(1)} | ${((purged.mb - empty.mb) / pages.length).toFixed(1)} | ${purged.heap.toFixed(1)} | -`,
    );
  }
  if (process.env.HIDDEN === "1" && hiddenPages.size) {
    const { page } = pages[0]!;
    const start = await page.evaluate(() => performance.now());
    await setHidden(page, false);
    hiddenPages.delete(page);
    const shown = await page.waitForFunction(
      (text) => (document.body.textContent?.includes(text) ? performance.now() : false),
      FIRST_TEXT,
      { timeout: 120_000, polling: "raf" },
    );
    const reshow = Number(await shown.jsonValue()) - start;
    console.log(`chat-pages-memory: a hidden chat shown again draws its newest reply in ${reshow.toFixed(0)} ms`);
    perfRow({ name: "chat_pages_memory.reshow", p50: reshow, p95: reshow, unit: "ms" });
  }
  if (warmLoads.length) {
    const sorted = [...warmLoads].sort((a, b) => a - b);
    const at = (share: number) => sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
    console.log(
      `chat-pages-memory: a chat built in the warm renderer shows its newest reply in p50 ${at(0.5).toFixed(0)} ms, p95 ${at(0.95).toFixed(0)} ms (n=${sorted.length})`,
    );
    perfRow({ name: "chat_pages_memory.warm_load", p50: at(0.5), p95: at(0.95), unit: "ms" });
  }
  await context.close();
} finally {
  await release();
}
