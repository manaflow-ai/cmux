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
// RELEASE=1 releases every chat but the newest instead, as the app gives back a hidden idle chat's page (HiddenChatPages,
// Leo 2026-11-14: "if something isn't drawn/is completely proven idle then dont bother taking memory"): the page closes,
// so a row is what released chats cost. After the last count, REOPEN (default 10) of them open again one at a time,
// each a new page in the warm renderer, timed from navigation to the newest reply drawn (chat_pages_memory.reopen:
// first content, p50/p95). With HIDDEN=1, REOPEN of the hidden chats show again the same way, each timed from shown to
// the newest reply drawn (chat_pages_memory.reshow p50/p95): the same open, of a kept page.
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
const RELEASE = process.env.RELEASE === "1";
const REOPEN = Number(process.env.REOPEN ?? 10);
// NOCHAT=1: each page is the pane with no chat attached (no session in its URL), so a row is what one more document
// of the app costs before any chat content: the share a chat would not pay if hidden chats shared one document.
const NOCHAT = process.env.NOCHAT === "1";
// SHARED=1: the hidden chats are views in one document (cut 2a, cmuxterm-hq goals/memory-per-chat.md): each count opens
// one page with that many chats mounted (`?mounts=N#sessions=…`, mountModel.tsx and dev-host/host.ts), every one but the
// newest display:none, and closes the page before it.
const SHARED = process.env.SHARED === "1";
// SHARED_HIDE=cv: hidden views use content-visibility:hidden (keeps layout and scroll) instead of display:none.
// SHARED_HIDE=vis: visibility:hidden (keeps style and layout; nothing paints).
const SHARED_HIDE = ["cv", "vis"].includes(process.env.SHARED_HIDE ?? "")
  ? (process.env.SHARED_HIDE as "cv" | "vis")
  : "none";
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
    // NOMINIFY=1: readable names in the idle wakeup sources.
    build: { outDir: out, emptyOutDir: true, ...(process.env.NOMINIFY === "1" ? { minify: false } : {}) },
    logLevel: "error",
  });
  // CSS=inline: the page's stylesheets as one inline <style>, as the page shipped them before; else linked
  // files the memory cache keeps (Cache-Control), as the shipped page links pane.css (build-agent-pane-web.sh).
  if (process.env.CSS === "inline") {
    const index = path.join(out, "index.html");
    const html = fs
      .readFileSync(index, "utf8")
      .replace(
        /<link rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g,
        (_, href: string) => `<style>${fs.readFileSync(path.join(out, href), "utf8")}</style>`,
      );
    fs.writeFileSync(index, html);
  }
  const cssHeaders: Record<string, string> = process.env.CSS === "inline" ? {} : { "cache-control": "max-age=3600" };
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      if (pathname === "/empty")
        return new Response("<!doctype html><title>empty</title>", { headers: { "content-type": "text/html" } });
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      if (!(await file.exists())) return new Response("not found", { status: 404 });
      return new Response(file, { headers: pathname.endsWith(".css") ? cssHeaders : {} });
    },
  });
  releases.push(() => statics.stop(true));
  const origin = `http://127.0.0.1:${statics.port}`;
  const urlFor = (index: number) =>
    `${origin}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux${NOCHAT ? "" : `&session=${sessionId(index)}`}`;

  // One renderer per site, as the app gives cmux-page (the fork's scheme-scoped switch; for one site the same).
  const server = await chromium.launchServer({
    headless: true,
    args: ["--process-per-site", "--js-flags=--expose-gc"],
  });
  releases.push(() => server.close());
  const root = server.process().pid!;
  const browser = await chromium.connect(server.wsEndpoint());
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  // MEMDUMP=1: Chromium's own accounting of the renderer by allocator (memory-infra), the owner split PSS hides:
  // v8, blink_gc, partition_alloc (and its partitions), malloc, cc (raster tiles), skia, font caches.
  const memoryDump = async (): Promise<Map<string, number>> => {
    const cdp = await browser.newBrowserCDPSession();
    const events: {
      ph?: string;
      pid?: number;
      args?: { dumps?: { allocators?: Record<string, { attrs?: Record<string, { value?: string }> }> } };
    }[] = [];
    cdp.on("Tracing.dataCollected", (data: { value: typeof events }) => events.push(...data.value));
    const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
    await cdp.send("Tracing.start", {
      transferMode: "ReportEvents",
      traceConfig: { includedCategories: ["disabled-by-default-memory-infra"], memoryDumpConfig: { triggers: [] } },
    } as never);
    await cdp.send("Tracing.requestMemoryDump", { deterministic: true, levelOfDetail: "detailed" } as never);
    await cdp.send("Tracing.end");
    await done;
    await cdp.detach();
    const pids = new Set(renderers(root));
    const sizes = new Map<string, number>();
    for (const event of events) {
      if (event.ph !== "v" || !pids.has(event.pid ?? -1)) continue;
      for (const [name, dump] of Object.entries(event.args?.dumps?.allocators ?? {})) {
        const depth = name.split("/").length;
        const keep =
          depth === 1 ||
          (name.startsWith("partition_alloc/partitions/") && depth === 3) ||
          (name.startsWith("v8/main/heap/") && depth === 4);
        const size = dump.attrs?.size?.value;
        if (!keep || size === undefined) continue;
        sizes.set(name, (sizes.get(name) ?? 0) + parseInt(size, 16) / 1048576);
      }
    }
    return sizes;
  };
  let lastDump: { count: number; sizes: Map<string, number> } | undefined;
  const printDump = async (count: number) => {
    if (process.env.MEMDUMP !== "1") return;
    const sizes = await memoryDump();
    const per = lastDump ? count - lastDump.count : 0;
    const rows = [...sizes].filter(([, mb]) => mb >= 0.05).sort((a, b) => b[1] - a[1]);
    console.log(
      `  memdump at ${count}: ${rows.map(([n, mb]) => `${n} ${mb.toFixed(1)}${per ? ` (+${((mb - (lastDump!.sizes.get(n) ?? 0)) / per).toFixed(2)}/chat)` : ""}`).join(", ")}`,
    );
    lastDump = { count, sizes };
  };
  await addStabilityProbe(context, { boxes: false });

  const sample = async (pages: { page: Page; cdp: CDPSession }[]) => {
    for (const { cdp } of pages) await cdp.send("HeapProfiler.collectGarbage");
    const heap = ((await pages[0]!.cdp.send("Runtime.getHeapUsage")) as { usedSize: number }).usedSize / 1048576;
    // Let the collections' freed pages go back before reading the process.
    await new Promise((resolve) => setTimeout(resolve, 1500));
    const pids = renderers(root);
    const mb = pids.reduce((sum, pid) => sum + pssMB(pid), 0);
    if (process.env.DETAIL === "1") {
      // Where the renderer's memory is: its mappings by name (PSS), the DOM it holds, and Blink's own counters.
      const byName = new Map<string, number>();
      for (const pid of pids) {
        let name = "";
        for (const line of fs.readFileSync(`/proc/${pid}/smaps`, "utf8").split("\n")) {
          const head = /^[0-9a-f]+-[0-9a-f]+ \S+ \S+ \S+ \S+\s*(.*)$/.exec(line);
          if (head) name = head[1] || "[anon]";
          const pss = /^Pss:\s+(\d+) kB/.exec(line);
          if (pss) byName.set(name, (byName.get(name) ?? 0) + Number(pss[1]) / 1024);
        }
      }
      const top = [...byName].sort((a, b) => b[1] - a[1]).slice(0, 8);
      console.log(`  smaps: ${top.map(([n, v]) => `${path.basename(n) || n} ${v.toFixed(1)}`).join(", ")}`);
      const dom = (await pages[0]!.cdp.send("Memory.getDOMCounters")) as Record<string, number>;
      console.log(`  dom (page 0): ${JSON.stringify(dom)}`);
      let nodes = 0;
      let rows = 0;
      for (const { page } of pages) {
        const counts = await page
          .evaluate(() => [document.getElementsByTagName("*").length, document.querySelectorAll(".acpmux-row").length])
          .catch(() => [0, 0]);
        nodes += counts[0]!;
        rows += counts[1]!;
      }
      console.log(`  elements (all pages): ${nodes}, transcript rows drawn: ${rows}`);
    }
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
  // HIDDEN_MINIMIZE=1: each hidden chat's window is minimized as well, so Chromium itself counts the page hidden
  // (WasHidden: its compositor turns invisible), as a cmux page whose window is ordered out.
  const browserCdp = await browser.newBrowserCDPSession();
  const setMinimized = async (cdp: CDPSession, minimized: boolean) => {
    if (process.env.HIDDEN_MINIMIZE !== "1") return;
    const { targetInfo } = await cdp.send("Target.getTargetInfo");
    const { windowId } = await browserCdp.send("Browser.getWindowForTarget", { targetId: targetInfo.targetId });
    await browserCdp.send("Browser.setWindowBounds", {
      windowId,
      bounds: { windowState: minimized ? "minimized" : "normal" },
    });
  };
  const hiddenPages = new Set<Page>();
  const warmLoads: number[] = [];
  let kindsAt: { count: number; sizes: Map<string, number> } | undefined;
  let first: { count: number; mb: number } | undefined;
  for (const count of COUNTS) {
    if (SHARED) {
      for (const entry of pages.splice(0)) {
        await entry.cdp.detach().catch(() => undefined);
        await entry.page.close();
      }
      const page = await context.newPage();
      const sessions = Array.from({ length: count }, (_, index) => sessionId(index)).join(",");
      await page.goto(
        `${origin}/?mounts=${count}#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&sessions=${sessions}`,
      );
      await page.waitForFunction(
        ([text, n]) => {
          const mounts = [...document.querySelectorAll<HTMLElement>("[data-pane-mount]")];
          const all = n === 1 ? [document.getElementById("root")!] : mounts;
          return all.length === n && all.every((el) => el.textContent?.includes(text as string));
        },
        [FIRST_TEXT, count] as const,
        { timeout: 300_000, polling: 500 },
      );
      await page.evaluate((mode) => {
        const mounts = [...document.querySelectorAll<HTMLElement>("[data-pane-mount]")];
        for (const el of mounts) el.style.cssText = "position:absolute;inset:0";
        for (const el of mounts.slice(0, -1)) {
          if (mode === "cv") el.style.contentVisibility = "hidden";
          else if (mode === "vis") el.style.visibility = "hidden";
          else el.style.display = "none";
        }
      }, SHARED_HIDE);
      pages.push({ page, cdp: await context.newCDPSession(page) });
    }
    while (!SHARED && pages.length < count) {
      const index = pages.length;
      const page = await context.newPage();
      await page.goto(urlFor(index));
      if (NOCHAT) {
        await page.waitForLoadState("load");
        await settledAt(page).catch(() => undefined);
        pages.push({ page, cdp: await context.newCDPSession(page) });
        continue;
      }
      const shown = await page.waitForFunction(
        (text) => (document.body.textContent?.includes(text) ? performance.now() : false),
        FIRST_TEXT,
        { timeout: 120_000, polling: "raf" },
      );
      // From navigation start to the newest reply drawn (page clock). After the first chat the renderer is warm,
      // as it is when a released hidden chat is built again (HiddenChatPages' idle release).
      if (index > 0) warmLoads.push(Number(await shown.jsonValue()));
      pages.push({ page, cdp: await context.newCDPSession(page) });
    }
    // The newest pages' own settling (read-ahead, fonts, the first paints) is not idle.
    await new Promise((resolve) => setTimeout(resolve, 3000));
    for (const { page } of pages) await settledAt(page).catch(() => undefined);
    if (RELEASE) {
      // Every chat but the newest is released: its page closes, as the app retires a released chat's page.
      for (const entry of pages.slice(0, -1)) {
        if (entry.page.isClosed()) continue;
        await entry.cdp.detach().catch(() => undefined);
        await entry.page.close();
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
    if (process.env.HIDDEN === "1" && !RELEASE) {
      for (const { page, cdp } of pages.slice(0, -1)) {
        if (hiddenPages.has(page)) continue;
        await setMinimized(cdp, true);
        await setHidden(page, true);
        hiddenPages.add(page);
      }
      // HIDDEN_FREEZE=1: then frozen, as the app freezes a hidden chat after browser.freezeHiddenTabs (30 s). DevTools'
      // freeze hides the page to Chromium first (CEFTab+Freeze.swift), so its compositor lets its tiles go.
      if (process.env.HIDDEN_FREEZE === "1") {
        await new Promise((resolve) => setTimeout(resolve, 6000));
        for (const { cdp } of pages.slice(0, -1))
          await cdp.send("Page.setWebLifecycleState", { state: "frozen" }).catch(() => undefined);
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
    const live = pages.filter(({ page }) => !page.isClosed());
    const idle = await measureIdle(
      live.map(({ page }) => ({ page, cdp: null })),
      IDLE_WINDOW_MS,
    );
    const wakeups = idle.reduce((sum, row) => sum + row.wakeups, 0) / (IDLE_WINDOW_MS / 1000);
    const sources = idle.flatMap((row) => row.sources).slice(0, 4);
    const now = await sample(live);
    await printDump(count);
    if (process.env.KINDS === "1") {
      const sizes = bySize(await takeSnapshot(live[0]!.cdp));
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
    // The goal's ratio (memory-per-chat, chat_memory_vs_empty_ratio): the renderer with 10 chats open over the empty
    // renderer, both from this same run (page-total form: 10 chats against none).
    if (count === 10 && empty.mb > 0) {
      const ratio = now.mb / empty.mb;
      console.log(`chat-pages-memory: renderer MB at 10 chats / empty: ${ratio.toFixed(3)}`);
      perfRow({ name: "chat_pages_memory.n10.ratio_vs_empty", p50: ratio, p95: ratio, unit: "ratio", floor: 0.05 });
    }
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
  const percentile = (values: number[], share: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
  };
  if (RELEASE && REOPEN > 0) {
    // Released chats open again one at a time: a new page in the warm renderer, then released again.
    const opens: number[] = [];
    for (let index = 0; index < Math.min(REOPEN, pages.length - 1); index++) {
      const page = await context.newPage();
      await page.goto(urlFor(index));
      const shown = await page.waitForFunction(
        (text) => (document.body.textContent?.includes(text) ? performance.now() : false),
        FIRST_TEXT,
        { timeout: 120_000, polling: "raf" },
      );
      opens.push(Number(await shown.jsonValue()));
      await page.close();
    }
    if (opens.length) {
      const [p50, p95] = [percentile(opens, 0.5), percentile(opens, 0.95)];
      console.log(
        `chat-pages-memory: a released chat opened again draws its newest reply in p50 ${p50.toFixed(0)} ms, p95 ${p95.toFixed(0)} ms (n=${opens.length})`,
      );
      perfRow({ name: "chat_pages_memory.reopen", p50, p95, unit: "ms" });
    }
  }
  if (SHARED && REOPEN > 0 && pages.length === 1) {
    // Switch back in the shared document: the visible view hides, a hidden one shows, timed to its second frame.
    // `atBottom` says whether the transcript is still at its newest reply (instant means no scroll jump).
    const profiling = process.env.PROFILE_SWITCH === "1";
    const tracing = process.env.TRACE_SWITCH === "1";
    const traceEvents: { name: string; ph: string; dur?: number; cat: string }[] = [];
    if (tracing) {
      pages[0].cdp.on("Tracing.dataCollected", (data) =>
        traceEvents.push(...(data.value as unknown as typeof traceEvents)),
      );
      await pages[0].cdp.send("Tracing.start", {
        categories: "devtools.timeline,disabled-by-default-devtools.timeline,cc,viz,blink",
        transferMode: "ReportEvents",
      });
    }
    if (profiling) {
      await pages[0].cdp.send("Profiler.enable");
      await pages[0].cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await pages[0].cdp.send("Profiler.start");
    }
    const switches = await pages[0].page.evaluate(
      async ([mode, n]) => {
        const mounts = [...document.querySelectorAll<HTMLElement>("[data-pane-mount]")];
        const hide = (el: HTMLElement, hidden: boolean) => {
          if (mode === "cv") el.style.contentVisibility = hidden ? "hidden" : "";
          else if (mode === "vis") el.style.visibility = hidden ? "hidden" : "";
          else el.style.display = hidden ? "none" : "";
        };
        const scroller = (root: HTMLElement) =>
          [...root.querySelectorAll<HTMLElement>("*")]
            .filter((el) => el.scrollHeight > el.clientHeight + 4 && /auto|scroll/.test(getComputedStyle(el).overflowY))
            .sort((a, b) => b.scrollHeight - a.scrollHeight)[0];
        const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
        const out: { ms: number; atBottom: boolean; layout: number; frame1: number }[] = [];
        let visible = mounts.length - 1;
        for (let step = 0; step < Math.min(n as number, mounts.length - 1); step++) {
          const target = step % (mounts.length - 1);
          const start = performance.now();
          hide(mounts[visible], true);
          hide(mounts[target], false);
          void mounts[target].offsetHeight;
          const layout = performance.now() - start;
          await frame();
          const frame1 = performance.now() - start;
          await frame();
          const ms = performance.now() - start;
          const el = scroller(mounts[target]);
          out.push({ ms, layout, frame1, atBottom: !el || el.scrollHeight - el.scrollTop - el.clientHeight < 8 });
          visible = target;
        }
        return out;
      },
      [SHARED_HIDE, REOPEN] as const,
    );
    if (tracing) {
      const done = new Promise((resolve) => pages[0].cdp.once("Tracing.tracingComplete", resolve));
      await pages[0].cdp.send("Tracing.end");
      await done;
      const sum = new Map<string, number>();
      for (const event of traceEvents)
        if (event.ph === "X" && event.dur) sum.set(event.name, (sum.get(event.name) ?? 0) + event.dur / 1000);
      for (const [name, ms] of [...sum].sort((a, b) => b[1] - a[1]).slice(0, 25))
        console.log(`chat-pages-memory: trace ${ms.toFixed(1)} ms  ${name}`);
    }
    if (profiling) {
      const { profile } = (await pages[0].cdp.send("Profiler.stop")) as {
        profile: {
          nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number } }[];
          samples: number[];
          timeDeltas: number[];
        };
      };
      const byNode = new Map(profile.nodes.map((node) => [node.id, node]));
      const self = new Map<string, number>();
      profile.samples.forEach((id, index) => {
        const frame = byNode.get(id)!.callFrame;
        const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").pop()}:${frame.lineNumber}`;
        self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
      });
      for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 25))
        console.log(`chat-pages-memory: profile self ${ms.toFixed(1)} ms  ${key}`);
    }
    if (switches.length) {
      const ms = switches.map((entry) => entry.ms);
      const [p50, p95] = [percentile(ms, 0.5), percentile(ms, 0.95)];
      const kept = switches.filter((entry) => entry.atBottom).length;
      const mid = (pick: (entry: (typeof switches)[number]) => number) =>
        percentile(switches.map(pick), 0.5).toFixed(0);
      console.log(
        `chat-pages-memory: shared switch split p50: style+layout ${mid((e) => e.layout)} ms, first frame ${mid((e) => e.frame1)} ms, second frame ${mid((e) => e.ms)} ms`,
      );
      console.log(
        `chat-pages-memory: a hidden view (${SHARED_HIDE}) shown again draws in p50 ${p50.toFixed(0)} ms, p95 ${p95.toFixed(0)} ms; ${kept}/${switches.length} kept their scroll at the newest reply`,
      );
      perfRow({ name: `chat_pages_memory.shared_reshow.${SHARED_HIDE}`, p50, p95, unit: "ms" });
    }
  }
  if (process.env.HIDDEN === "1" && !RELEASE && hiddenPages.size > 1 && REOPEN > 1) {
    // The same open of kept pages: REOPEN hidden chats shown again one at a time, then hidden again.
    const reshows: number[] = [];
    for (const { page, cdp } of pages.slice(1, Math.min(REOPEN, pages.length - 1) + 1)) {
      if (!hiddenPages.has(page)) continue;
      if (process.env.HIDDEN_FREEZE === "1") await cdp.send("Page.setWebLifecycleState", { state: "active" });
      const start = await page.evaluate(() => performance.now());
      await setMinimized(cdp, false);
      await setHidden(page, false);
      const shown = await page.waitForFunction(
        (text) => (document.body.textContent?.includes(text) ? performance.now() : false),
        FIRST_TEXT,
        { timeout: 120_000, polling: "raf" },
      );
      reshows.push(Number(await shown.jsonValue()) - start);
      await setHidden(page, true);
      await setMinimized(cdp, true);
    }
    if (reshows.length) {
      const [p50, p95] = [percentile(reshows, 0.5), percentile(reshows, 0.95)];
      console.log(
        `chat-pages-memory: a hidden chat shown again draws its newest reply in p50 ${p50.toFixed(0)} ms, p95 ${p95.toFixed(0)} ms (n=${reshows.length})`,
      );
      perfRow({ name: "chat_pages_memory.reshow_many", p50, p95, unit: "ms" });
    }
  }
  if (process.env.HIDDEN === "1" && !RELEASE && hiddenPages.size) {
    const { page, cdp } = pages[0]!;
    if (process.env.HIDDEN_FREEZE === "1") await cdp.send("Page.setWebLifecycleState", { state: "active" });
    const start = await page.evaluate(() => performance.now());
    await setMinimized(cdp, false);
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
