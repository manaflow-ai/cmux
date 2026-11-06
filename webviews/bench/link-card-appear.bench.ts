// l10n-allow-file: bench fixture replies, not shipped UI.
// A pull request link's hover card appearing (chips/LinkHoverCard.tsx), in the real pane (a
// production build of its dev entry and a stand-in acpmux, as thread-rail-hover.bench.ts) on
// Chromium. Leo, 2026-11-06: "when I hover on a link, it plays this really laggy, slow animation for
// the GitHub ones". A reply under a long chat holds HOVERS pull request links; the pointer rests on
// each until its card opens (the card dwell), stays WINDOW_MS, then leaves. From the moment the card
// mounts the page stamps every animation frame for WINDOW_MS; a Chrome trace of the renderer's main
// thread gives the busy time of each of those frames. The page also measures, per card, how long it
// takes to reach its final look (opacity 1, no rise left) and whether its height changes after its
// first frame (a pop-in: a row the host's answer adds later).
//   bun bench/link-card-appear.bench.ts [rounds=3] [turns=300]
// ARMS=plain,seethrough: `seethrough` sets data-cmux-see-through on the root, as the app's see-through
// page does. The host's pull request answer is stubbed: CACHED=1 (default) answers every ask from the
// cache at once, as the host does for a link it read in the last minute; CACHED=0 has no cache, and
// the full read lands READ_MS (default 150) after the card asks, as a first gh read would.
// VARIANTS=build,rise120,fade80,instant runs each arm with the card's appear as the build has it
// (`build`), or overridden by a stylesheet: the 120 ms fade with the 2 px rise (the old appear),
// an 80 ms fade with no rise, or no appear transition at all (the design comparison, one harness).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { PERF_ROW_MARK } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 3);
const TURNS = Number(process.argv[3] ?? 300);
const ARMS = (process.env.ARMS?.split(",") ?? ["plain", "seethrough"]) as readonly string[];
const HOVERS = Number(process.env.HOVERS ?? 6);
const CACHED = process.env.CACHED !== "0";
const WINDOW_MS = Number(process.env.WINDOW_MS ?? (CACHED ? 400 : 1800));
const READ_MS = Number(process.env.READ_MS ?? 150);
const VARIANTS = (process.env.VARIANTS?.split(",") ?? ["build"]) as readonly string[];
const VARIANT_CSS: Record<string, string> = {
  build: "",
  rise120: ".cv-link-preview.ui-tooltip{--tooltip-fade-in:120ms;--tooltip-rise:2px}.cv-link-preview.ui-tooltip:not([data-ending-style]){transition:opacity 120ms ease-out,translate 120ms ease-out}", // prettier-ignore
  fade80: ".cv-link-preview.ui-tooltip{--tooltip-rise:0px}.cv-link-preview.ui-tooltip:not([data-ending-style]){transition:opacity 80ms ease-out}", // prettier-ignore
  instant: ".cv-link-preview.ui-tooltip:not([data-ending-style]){transition:none}",
};
const KEEP_TRACES = process.env.KEEP_TRACES === "1";
const webviews = path.resolve(import.meta.dir, "..");
const PROD_DIR = process.env.PROD_DIR;
const log = (...args: unknown[]) => console.error("link-card-appear:", ...args);

async function buildPane(): Promise<string> {
  if (PROD_DIR) return PROD_DIR;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "link-card-pane-"));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
  log(`built the pane's dev entry into ${out}`);
  return out;
}

const LINKS = Array.from({ length: HOVERS }, (_, i) => `https://github.com/manaflow-ai/cmux/pull/${37150 + i}`);
const reply = [
  "Landed the fixes:",
  "",
  ...LINKS.map((link, i) => `- ${link} fixes papercut ${i + 1}, and the checks on its head are green.`),
].join("\n");
const { events, session } = papercutEvents({
  turns: TURNS,
  running: false,
  extra: [
    ["mux", "user_message", { text: "What landed?" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } } }, // prettier-ignore
      },
    ],
    ["mux", "turn_result", { status: "completed" }],
  ],
});
const answer = (method: string): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach":
      return { session, lastSeq: events.length, events, hasMore: false };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
};
let url = "";

/// The page's host for `pr.inspect` (chips/pullRequestStore.ts): the full pull request the card
/// draws in the screenshot Leo sent (state, author, files, branches, a label).
function installHost({ cached, readMs }: { cached: boolean; readMs: number }) {
  const full = (link: string) => {
    const number = Number(link.split("/").pop());
    return {
      number,
      title: "fix(cmux-wg): a dial waiting on a handshake resends its initiation every second",
      state: "merged",
      url: link,
      author: "teamleaderleo",
      updatedAt: new Date(Date.now() - 5 * 60_000).toISOString(),
      additions: 86,
      deletions: 0,
      changedFiles: 3,
      files: [
        { path: "cmux-wg/src/dial.rs", additions: 49, deletions: 0 },
        { path: "cmux-wg/tests/dial.rs", additions: 37, deletions: 0 },
        { path: "cmux-wg/tests/handshake.rs", additions: 0, deletions: 0 },
      ],
      labels: ["risk:normal"],
      baseRef: "feat-cmux-next",
      headRef: "lane/wg-dial-handshake-retry",
    };
  };
  const now = () => Date.now() / 1000;
  const read = new Map<string, number>();
  const inspect = (params: { url: string; cached?: boolean }): Promise<unknown> => {
    const link = params.url;
    const done = { pullRequest: full(link), fetchedAt: now(), reading: false };
    if (cached) return Promise.resolve(done);
    if (params.cached) return Promise.resolve({ pullRequest: null, reading: false });
    // A first read, as the host does it: the card's ask starts it and is told "reading" at once;
    // the card asks again every 1.5 s while it reads, and an ask READ_MS after the start gets it.
    if (!read.has(link)) read.set(link, performance.now());
    return Promise.resolve(performance.now() - read.get(link)! < readMs ? { pullRequest: null, reading: true } : done);
  };
  // The dev host (dev-host/host.ts) installs the page host's bridge, cmuxPage, unless one is there;
  // this one answers `cmux.agent.pr.inspect` itself and hands every other envelope to the dev host's.
  let original: { postMessage(message: unknown): unknown } | undefined;
  const wrapped = {
    postMessage(message: { t?: string; id?: number; op?: string; params?: { url: string; cached?: boolean } }) {
      if (message?.t === "call" && message.op === "cmux.agent.pr.inspect" && message.params?.url)
        return inspect(message.params).then((value) => ({ t: "ok", id: message.id, value }));
      return original!.postMessage(message);
    },
  };
  const handlers: Record<string, unknown> = {};
  Object.defineProperty(handlers, "cmuxPage", {
    enumerable: true,
    configurable: true,
    get: () => (original ? wrapped : undefined),
    set: (value) => void (original = value),
  });
  (window as any).webkit = { messageHandlers: handlers };
}

async function open(browser: Browser, arm: string, variant: string): Promise<Page> {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  await page.addInitScript(installHost, { cached: CACHED, readMs: READ_MS });
  await page.addInitScript((seeThrough) => {
    if (seeThrough) document.documentElement.setAttribute("data-cmux-see-through", "");
  }, arm === "seethrough");
  const said: string[] = [];
  page.on("console", (m) => void ((m.type() === "error" || m.type() === "warning") && said.push(`${m.type()}: ${m.text()}`))); // prettier-ignore
  page.on("pageerror", (error) => said.push(`page error: ${error.message}`));
  await page.goto(url);
  try {
    await page.locator(`a.cv-chip[href="${LINKS.at(-1)}"]`).waitFor({ timeout: 180_000 });
  } catch (error) {
    log(`the chat or its links never showed (${arm})\n${said.slice(0, 40).join("\n")}`);
    throw error;
  }
  if (arm === "seethrough")
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
  if (VARIANT_CSS[variant]) await page.addStyleTag({ content: VARIANT_CSS[variant] });
  await page.waitForTimeout(1500);
  return page;
}

type CardRun = { appearMs: number; popIn: boolean; firstHeight: number; lastHeight: number; growth: number; frames: number }; // prettier-ignore

/// Watches for each card's mount and stamps its frames for `windowMs`.
async function probe(page: Page, windowMs: number) {
  await page.evaluate((span) => {
    const w = window as any;
    w.benchCards = [] as CardRun[];
    const seen = new WeakSet<HTMLElement>();
    const follow = (card: HTMLElement) => {
      if (seen.has(card)) return;
      seen.add(card);
      const start = performance.now();
      const index = w.benchCards.length;
      const run = { appearMs: -1, popIn: false, firstHeight: -1, lastHeight: -1, growth: 0, frames: 0 };
      w.benchCards.push(run);
      console.timeStamp(`w${index}-begin`);
      const frame = (now: number) => {
        if (now - start > span) {
          console.timeStamp(`w${index}-end`);
          return;
        }
        console.timeStamp("f");
        run.frames += 1;
        const style = getComputedStyle(card);
        const height = card.getBoundingClientRect().height;
        if (run.firstHeight < 0) run.firstHeight = height;
        else if (Math.abs(height - run.lastHeight) > 0.5) run.popIn = true;
        run.growth = Math.max(run.growth, Math.abs(height - run.firstHeight));
        run.lastHeight = height;
        const rise = style.translate === "none" ? 0 : Math.abs(Number.parseFloat(style.translate.split(" ")[1] ?? "0") || 0); // prettier-ignore
        if (run.appearMs < 0 && Number.parseFloat(style.opacity) >= 1 && rise < 0.01) run.appearMs = now - start;
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
    };
    new MutationObserver((records) => {
      for (const record of records)
        for (const node of record.addedNodes) {
          if (!(node instanceof HTMLElement)) continue;
          const card = node.matches(".cv-link-preview") ? node : node.querySelector<HTMLElement>(".cv-link-preview");
          if (card) follow(card);
        }
    }).observe(document.body, { childList: true, subtree: true });
  }, windowMs);
}

async function hoverAll(page: Page): Promise<CardRun[]> {
  await probe(page, WINDOW_MS);
  await page.evaluate(() => console.timeStamp("bench-begin"));
  for (const link of LINKS) {
    const chip = page.locator(`a.cv-chip[href="${link}"]`);
    await chip.scrollIntoViewIfNeeded();
    const box = (await chip.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 4 });
    await page.locator(".cv-link-preview").first().waitFor({ timeout: 5_000 });
    await page.waitForTimeout(WINDOW_MS + 100);
    if (process.env.DEBUG)
      log(
        await page
          .locator(".cv-link-preview")
          .first()
          .evaluate((e) => e.textContent),
      );
    await page.mouse.move(5, 5, { steps: 2 });
    await page.locator(".cv-link-preview").first().waitFor({ state: "detached", timeout: 5_000 });
    await page.waitForTimeout(200);
  }
  await page.evaluate(() => console.timeStamp("bench-end"));
  return (await page.evaluate(() => (window as any).benchCards)) as CardRun[];
}

type TraceEvent = { name: string; cat: string; ph: string; ts: number; dur?: number; pid: number; tid: number; args?: any }; // prettier-ignore

function merge(intervals: [number, number][]): [number, number][] {
  intervals.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const [a, b] of intervals) {
    const last = merged.at(-1);
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  return merged;
}
function binned(intervals: [number, number][], edges: number[]): number[] {
  const out = Array.from({ length: Math.max(0, edges.length - 1) }, () => 0);
  let first = 0;
  for (const [a, b] of merge(intervals)) {
    while (first < out.length && edges[first + 1]! <= a) first++;
    for (let slot = first; slot < out.length && edges[slot]! < b; slot++)
      out[slot] += Math.max(0, Math.min(b, edges[slot + 1]!) - Math.max(a, edges[slot]!));
  }
  return out;
}
const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))] ?? 0;
};

/// Each card window's frames: main-thread busy per frame and the gaps between frames.
function analyze(file: string) {
  const all = (JSON.parse(fs.readFileSync(file, "utf8")) as { traceEvents: TraceEvent[] }).traceEvents;
  const stamps = all.filter((e) => e.name === "TimeStamp");
  const begin = stamps.find((e) => e.args?.data?.message === "bench-begin");
  if (!begin) throw new Error("no bench marks in the trace");
  const on = all.filter((e) => e.pid === begin.pid && e.tid === begin.tid && e.ph === "X" && e.dur !== undefined);
  const tasks = on
    .filter((e) => e.name === "ThreadControllerImpl::RunTask" || e.name === "RunTask")
    .map((e) => [e.ts / 1000, (e.ts + e.dur!) / 1000] as [number, number]);
  // The display compositor (filters drawn there) and the raster workers, by thread name.
  const threadNames = new Map(all.filter((e) => e.ph === "M" && e.name === "thread_name").map((e) => [`${e.pid}:${e.tid}`, String(e.args?.name)])); // prettier-ignore
  const onThread = (test: (name: string) => boolean, task: (e: TraceEvent) => boolean) =>
    all
      .filter((e) => e.ph === "X" && e.dur !== undefined && task(e) && test(threadNames.get(`${e.pid}:${e.tid}`) ?? ""))
      .map((e) => [e.ts / 1000, (e.ts + e.dur!) / 1000] as [number, number]);
  const viz = onThread(
    (n) => n === "VizCompositorThread",
    (e) => e.name === "ThreadControllerImpl::RunTask",
  );
  const raster = onThread((n) => n.startsWith("ThreadPoolForegroundWorker") || n.startsWith("CompositorTileWorker"), (e) => e.name === "TaskGraphRunner::RunTask"); // prettier-ignore
  const frames = stamps.filter((e) => e.pid === begin.pid && e.args?.data?.message === "f").map((e) => e.ts / 1000);
  const busy: number[] = [];
  const vizBusy: number[] = [];
  const rasterBusy: number[] = [];
  const gaps: number[] = [];
  for (let index = 0; ; index++) {
    const from = stamps.find((e) => e.args?.data?.message === `w${index}-begin`);
    const to = stamps.find((e) => e.args?.data?.message === `w${index}-end`);
    if (!from || !to) break;
    const edges = [from.ts / 1000, ...frames.filter((t) => t > from.ts / 1000 && t < to.ts / 1000)].sort((a, b) => a - b); // prettier-ignore
    busy.push(...binned(tasks, edges));
    vizBusy.push(...binned(viz, edges));
    rasterBusy.push(...binned(raster, edges));
    gaps.push(...edges.slice(2).map((t, i) => t - edges[i + 1]!));
  }
  return {
    busyP50: pct(busy, 50),
    busyP95: pct(busy, 95),
    busyMax: Math.max(0, ...busy),
    vizP95: pct(vizBusy, 95),
    vizMax: Math.max(0, ...vizBusy),
    rasterP95: pct(rasterBusy, 95),
    rasterMax: Math.max(0, ...rasterBusy),
    gapP95: pct(gaps, 95),
    gapMax: Math.max(0, ...gaps),
    over16: busy.filter((b) => b > 16.7).length,
    dropped: gaps.filter((g) => g > 16.7 * 1.5).length,
    frames: busy.length,
  };
}

const results: Record<string, { trace: ReturnType<typeof analyze>; cards: CardRun[] }[]> = {};
const releases: Array<[string, () => unknown]> = [];
try {
  const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "link-card-bench-"));
  releases.push(["traces", () => (KEEP_TRACES ? log(`traces kept in ${tmp}`) : fs.rmSync(tmp, { recursive: true, force: true }))]); // prettier-ignore
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string };
        if (message.id !== undefined)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
      },
    },
  });
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);
  const prodDir = await buildPane();
  if (!PROD_DIR) releases.push(["pane build", () => fs.rmSync(prodDir, { recursive: true, force: true })]);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(prodDir, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
    headless: true,
  });
  releases.push(["browser", () => browser.close()]);
  for (let round = 0; round < ROUNDS; round++) {
    const arms = ARMS.flatMap((arm) => VARIANTS.map((variant) => [arm, variant] as const));
    for (const [arm, variant] of round % 2 ? [...arms].reverse() : arms) {
      const page = await open(browser, arm, variant);
      const file = path.join(tmp, `${arm}-${variant}-${round}.json`);
      await browser.startTracing(page, { path: file, categories: ["devtools.timeline", "toplevel", "blink.console"] });
      const cards = await hoverAll(page);
      await browser.stopTracing();
      if (process.env.DEBUG) log(JSON.stringify(cards));
      (results[variant === "build" ? arm : `${arm}/${variant}`] ??= []).push({ trace: analyze(file), cards });
      await page.close();
    }
  }
} finally {
  for (const [name, release] of releases.reverse()) {
    try {
      await release();
    } catch (error) {
      log(`could not release the ${name}:`, error);
    }
  }
}

const median = (v: number[]) => pct(v, 50);
const fmt = (n: number) => n.toFixed(1).padStart(6);
console.log(
  `turns=${TURNS} rounds=${ROUNDS} hovers=${HOVERS} window=${WINDOW_MS}ms cached=${CACHED}${CACHED ? "" : ` read=${READ_MS}ms`} (medians of rounds)`,
);
console.log("arm                 main p50 main p95 main max  viz p95 viz max rast p95 rast max  gap p95 gap max  >16ms dropped frames | appear p50 appear max popIns growth max px"); // prettier-ignore
for (const [arm, runs] of Object.entries(results)) {
  const m = (pick: (r: ReturnType<typeof analyze>) => number) => median(runs.map((r) => pick(r.trace)));
  const cards = runs.flatMap((r) => r.cards);
  const appear = cards.map((c) => (c.appearMs < 0 ? WINDOW_MS : c.appearMs));
  const popIns = cards.filter((c) => c.popIn).length;
  console.log(
    `${arm.padEnd(19)} ${fmt(m((r) => r.busyP50))}   ${fmt(m((r) => r.busyP95))}   ${fmt(m((r) => r.busyMax))}  ${fmt(m((r) => r.vizP95))} ${fmt(m((r) => r.vizMax))}  ${fmt(m((r) => r.rasterP95))}   ${fmt(m((r) => r.rasterMax))}  ${fmt(m((r) => r.gapP95))}  ${fmt(m((r) => r.gapMax))}  ${String(m((r) => r.over16)).padStart(5)} ${String(m((r) => r.dropped)).padStart(7)} ${String(m((r) => r.frames)).padStart(6)} | ${fmt(pct(appear, 50))}     ${fmt(Math.max(...appear))}    ${popIns}/${cards.length} ${Math.max(
      0,
      ...cards.map((c) => c.growth),
    )
      .toFixed(0)
      .padStart(6)}`,
  );
  console.log(
    `${PERF_ROW_MARK}${JSON.stringify({ name: `link_card_appear.${arm.replace("/", ".")}.busy`, p50: m((r) => r.busyP50), p95: m((r) => r.busyP95), unit: "ms" })}`,
  );
}
