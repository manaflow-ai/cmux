// l10n-allow-file: bench fixture prompts and replies, and benchmark output, not shipped UI.
// A chat's first load after a restart, frame by frame (Leo, 2026-11-09, after "restart to update" on the
// nightly: "the chat loading kinda flickered in and out and layout shifted... our first loads aren't
// perfected yet? at least after restart?"). A first load is a state transition: its first painted frame
// should be its final state, it never blanks a pane that had content, and nothing in it moves.
//
// After an update the app restarts acpmux, and the chat's page boots while acpmux is not up yet. The page
// draws the chat's saved copy in its first frame (chatSnapshot/boot.ts, served as `__snapshot/chat.js`),
// and the host's kept tail (`chat.tail.get`) may draw rows under it while the socket connects (direct.ts
// `drawTailWhileConnecting`). Then the first handshake fails quietly (hostRetry.ts `hostIsReconnecting`)
// and the page retries about every 2 s until acpmux answers. This bench replays that with the production
// pane (a vite build of the pane's dev entry, as chat-open.bench.ts builds it) served as the app serves
// it: one `<style id="cmux-pane-styles">` with every sheet, and the copy's two scripts before the module.
//
// Each round, per mode:
//   warm      a fresh context opens the TURNS-turn chat with acpmux up, waits until the newest answer
//             painted and the page was quiet SETTLE_QUIET_MS, and writes the copy (chatSnapshot/capture.ts).
//   relaunch  a new (cold) context opens the same chat, served that copy and the chat's kept tail by the
//             host, with acpmux unavailable for ACPMUX_DOWN_MS from navigation:
//               down       the socket is refused (HTTP 503, no upgrade), as while acpmux restarts;
//               slow-init  the socket opens but `initialize` answers only then, as a slow daemon does.
//             Every painted frame until ACPMUX_DOWN_MS + 4000 ms is read after it painted
//             (test/support/paintedFrames.ts) from the layer on top: the copy's shadow root while it
//             shows, else the live page.
// Per round (bench/firstLoadFrames.ts): blank frames after the first content, shift frames (the composer
// or the bottom-most row in view moved, or that row was replaced), when the final state first painted,
// when content first painted; and the layout-shift entries' sum.
//   [MODE=all|down|slow-init] [ROUNDS=3] [TURNS=120] [ACPMUX_DOWN_MS=3000] [GATE=1] [TRACE=1] \
//     bun bench/first-load-after-restart.bench.ts
// GATE=1 exits 1 when any round blanked or shifted; otherwise it always exits 0. TRACE=1 prints each
// mode's worst round frame by frame. One `FIRST_LOAD_JSON {...}` line carries every number.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import {
  PAGE_STYLE_ID,
  SNAPSHOT_BOOT_GLOBAL,
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_THEME_GLOBAL,
  type ChatSnapshot,
} from "../src/agent-session/acpmux/chatSnapshot/shared";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { classifyFrames, type FrameMetrics, type FrameRecord } from "./firstLoadFrames";
import { perfRow } from "./perfRow";
import { newestPage } from "./daemonPage";

const MODES_ALL = ["down", "slow-init"] as const;
type Mode = (typeof MODES_ALL)[number];
const MODE = process.env.MODE ?? "all";
if (MODE !== "all" && !(MODES_ALL as readonly string[]).includes(MODE))
  throw new Error(`MODE must be all, ${MODES_ALL.join(" or ")}`);
const MODES: readonly Mode[] = MODE === "all" ? MODES_ALL : [MODE as Mode];
const ROUNDS = Number(process.env.ROUNDS ?? 3);
const TURNS = Number(process.env.TURNS ?? 120);
const DOWN_MS = Number(process.env.ACPMUX_DOWN_MS ?? 3000);
for (const [name, value] of [
  ["ROUNDS", ROUNDS],
  ["TURNS", TURNS],
  ["ACPMUX_DOWN_MS", DOWN_MS],
] as const)
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number`);
/// How long each relaunch is recorded from navigation: acpmux's absence, the page's next retry (at most
/// 2 s apart while it recovers, hostRetry.ts `nextRetryDelay`), the attach and the settle after it.
const RECORD_MS = DOWN_MS + 4000;
/// The warm page is settled once the newest answer painted and nothing in view changed this long.
const SETTLE_QUIET_MS = 600;
const GATE = process.env.GATE === "1";
const TRACE = process.env.TRACE === "1";
/// The theme key the copy is written under and the host says the page gets now (shared.ts `misfit`):
/// the bench's host sends the page no theme, so any fixed key is the same theme on both loads.
const THEME = "bench-theme";
/// The copy is drawn only at the viewport it was written at (shared.ts `misfit`): both loads use this.
const VIEWPORT = { width: 1200, height: 800 };
const LATEST = `Answer ${TURNS}:`;
const webviews = path.resolve(import.meta.dir, "..");
const chatSnapshotSource = path.join(webviews, "src/agent-session/acpmux/chatSnapshot");

const { events, session } = papercutEvents({ turns: TURNS, running: false });
/// The newest page before `beforeSeq`, oldest first, and whether older ones remain: the page the daemon
/// answers an attach or an older-history read with, cut by count and by `maxBytes` (daemonPage.ts).
const newest = (limit: number, beforeSeq = Infinity, maxBytes?: unknown) =>
  newestPage(events, { limit, beforeSeq, maxBytes });
/// What the app host keeps for this chat and answers `chat.tail.get` with (tailCache.ts `KeptTail`, read
/// back by `tailFromHost`): the newest KEPT_EVENTS (400) records, as the page hands them over
/// (direct.ts `currentTail`), and the chat's summary. A finished chat whose kept page starts at a prompt
/// needs no turn opener.
const KEPT_EVENTS = 400;
const keptTail = {
  events: newest(KEPT_EVENTS).page,
  summary: session,
  historyExhausted: events.length <= KEPT_EVENTS,
  queue: [],
  configSeq: 0,
  usageFromSeq: 0,
};

const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
      };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach": {
      // As the daemon does: the newest `limit` events within `maxBytes`, and hasMore while older ones remain.
      const { page, hasMore } = newest(Number(params.limit ?? 400), Infinity, params.maxBytes);
      return { session, lastSeq: events.at(-1)?.seq ?? 0, events: page, hasMore };
    }
    case "_acpmux/events": {
      // The prompt index (hub/paging.rs prompt_index): every prompt before `beforeSeq`, each cut to its text.
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
        return { events: prompts, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newest(Number(params.limit ?? 400), Number(params.beforeSeq), params.maxBytes);
        return { events: page, hasMore, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      return { events: [], hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    }
    default:
      return null;
  }
};

/// A painted frame as the page records it: the classified fields, plus what a trace prints.
type Painted = FrameRecord & {
  /// The bottom-most row's text, cut short.
  bottomText: string;
  /// The live root was held clear (opacity 0) with no copy over it: nothing of the chat showed.
  rootHidden: boolean;
};
type Recording = {
  frames: Painted[];
  /// The layout-shift entries' sum over the recording (none with recent input).
  layoutShift: number;
  latestAt: number;
  /// When the live page itself (no copy over it) first showed the newest answer, else 0.
  liveLatestAt: number;
  changedAt: number;
  done: boolean;
  stop: () => void;
};
type BenchWindow = {
  __firstLoad: Recording;
  __benchHost: { tailAskedAt: number; tailCalls: number };
  __cmuxChatSnapshotMiss?: string;
  __cmuxChatSnapshotShown?: { at: number; swappedAt?: number };
  captureSnapshot: (doc: Document, theme: string) => ChatSnapshot | undefined;
  captureMiss: () => string;
};

/// The page's host actions this bench answers (as the app's host would), installed before the page's
/// scripts: the kept tail (`chat.tail.get`, null on the warm load: the host holds none) and the reading
/// place (`chat.scrollAnchor.get`: null, the chat opens at its newest message). The page assigns its own
/// `window.cmuxAcpmuxActions` once its client is up (App.tsx); these stay beside its own, as the app's
/// host keeps answering them. Runs in the page, so it closes over nothing.
function installHost({ tail }: { tail: unknown }) {
  const asked = { tailAskedAt: 0, tailCalls: 0 };
  (window as unknown as { __benchHost: typeof asked }).__benchHost = asked;
  const served: Record<string, (params: Record<string, unknown>) => Promise<unknown>> = {
    "chat.tail.get": async () => {
      asked.tailAskedAt ||= performance.now();
      asked.tailCalls += 1;
      // A copy per answer: the page keeps and edits what it is handed.
      return tail === null ? null : structuredClone(tail);
    },
    "chat.scrollAnchor.get": async () => null,
  };
  let current: Record<string, unknown> = { ...served };
  Object.defineProperty(window, "cmuxAcpmuxActions", {
    configurable: true,
    get: () => current,
    set: (next: unknown) => {
      current = next && typeof next === "object" ? (next as Record<string, unknown>) : {};
      for (const [method, run] of Object.entries(served)) if (!(method in current)) current[method] = run;
    },
  });
}

/// Records every painted frame from navigation for `windowMs` (window.cmuxAfterPaint, so each read is of
/// a frame that painted, after its ResizeObservers): the layer on top, which is the copy's shadow root
/// while a `hostTag` element shows, else the live document. Per frame: the transcript rows intersecting
/// the scroller's viewport (`.acpmux-row[data-row-id]`, VirtualTranscript.tsx; a row at opacity 0 is
/// not in view), the composer's box (`.acpmux-composer-box`, ComposerBox.tsx) and the scroller's offset.
/// Also keeps when the newest answer first showed and when what shows last changed (the warm load's
/// settle). Runs in the page, so it closes over nothing.
function recordFrames({ windowMs, latest, hostTag }: { windowMs: number; latest: string; hostTag: string }) {
  type Row = { id: string; top: number };
  type Frame = {
    t: number;
    copyShown: boolean;
    rows: Row[];
    composer: { top: number; height: number } | null;
    scrollTop: number | null;
    bottomText: string;
    rootHidden: boolean;
  };
  let stopped = false;
  const recording = {
    frames: [] as Frame[],
    layoutShift: 0,
    latestAt: 0,
    liveLatestAt: 0,
    changedAt: 0,
    done: false,
    stop: () => {
      stopped = true;
      recording.done = true;
    },
  };
  (window as unknown as { __firstLoad: typeof recording }).__firstLoad = recording;
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries() as unknown as { value: number; hadRecentInput: boolean; startTime: number }[])
      if (!entry.hadRecentInput && entry.startTime <= windowMs) recording.layoutShift += entry.value;
  }).observe({ type: "layout-shift", buffered: true });
  let signature = "";
  const read = (): Frame => {
    const host = document.querySelector(hostTag);
    const scope: ParentNode = host?.shadowRoot ?? document;
    // Under a copy the live root is held clear until the swap (chatSnapshot/paint.ts); with no copy over
    // it, a clear root shows nothing of the chat.
    const rootHidden = !host && document.getElementById("root")?.style.opacity === "0";
    const scroller = scope.querySelector<HTMLElement>(".acpmux-scroll");
    const view = rootHidden ? undefined : scroller?.getBoundingClientRect();
    const rows: (Row & { text: string })[] = [];
    if (view)
      for (const row of Array.from(scope.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))) {
        const box = row.getBoundingClientRect();
        if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
        if (Number(getComputedStyle(row).opacity) === 0) continue;
        rows.push({ id: row.dataset.rowId ?? "", top: box.top, text: row.textContent ?? "" });
      }
    rows.sort((a, b) => a.top - b.top);
    const composer = rootHidden
      ? undefined
      : Array.from(scope.querySelectorAll(".acpmux-composer-box"))
          .map((element) => element.getBoundingClientRect())
          .find((box) => box.height > 0);
    if (!recording.latestAt && rows.some((row) => row.text.includes(latest))) recording.latestAt = performance.now();
    if (!recording.liveLatestAt && !host && !rootHidden && rows.some((row) => row.text.includes(latest)))
      recording.liveLatestAt = performance.now();
    return {
      t: performance.now(),
      copyShown: !!host,
      rows: rows.map(({ id, top }) => ({ id, top })),
      composer: composer ? { top: composer.top, height: composer.height } : null,
      scrollTop: scroller && !rootHidden ? scroller.scrollTop : null,
      bottomText: (rows.at(-1)?.text ?? "").trim().replace(/\s+/g, " ").slice(0, 48),
      rootHidden,
    };
  };
  window.cmuxAfterPaint(() => {
    if (stopped) return false;
    if (performance.now() > windowMs) {
      recording.stop();
      return false;
    }
    const frame = read();
    recording.frames.push(frame);
    const next = JSON.stringify([
      frame.rows.map((row) => [row.id, Math.round(row.top)]),
      frame.composer && [Math.round(frame.composer.top), Math.round(frame.composer.height)],
      frame.scrollTop === null ? null : Math.round(frame.scrollTop),
    ]);
    if (next !== signature) {
      signature = next;
      recording.changedAt = frame.t;
    }
    return true;
  });
}

type Round = {
  mode: Mode;
  metrics: FrameMetrics;
  frames: Painted[];
  /// When the live page, with no copy over it, first showed the newest answer (ms from navigation),
  /// else null: a round whose copy never gave way to the read chat has not loaded.
  liveLatestMs: number | null;
  layoutShift: number;
  /// When the copy drew and when the live page took over (chatSnapshot/paint.ts, live.ts), ms from navigation.
  copyShownMs: number | null;
  swapMs: number | null;
  /// Why no copy drew (boot.ts), or null when one did.
  copyMiss: string | null;
  tailAskedMs: number | null;
  /// When the stand-in acpmux started answering, ms from navigation.
  acpmuxUpMs: number;
  /// Socket upgrades refused while acpmux was down.
  refused: number;
  socketOpenedMs: number | null;
  initializeAnsweredMs: number | null;
  attachAnsweredMs: number | null;
};

const releases: [string, () => unknown][] = [];
const release = async () => {
  for (const [, stop] of releases.reverse()) await Promise.resolve(stop()).catch(() => undefined);
};

try {
  /// acpmux is unavailable until `downUntil` (epoch ms) in `downMode`; up otherwise.
  let downMode: Mode | undefined;
  let downUntil = 0;
  /// This relaunch's socket timeline (epoch ms).
  let load = { refused: 0, socketOpenedAt: 0, initializeAnsweredAt: 0, attachAnsweredAt: 0 };
  const delayedReplies = new Set<ReturnType<typeof setTimeout>>();
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      // As while acpmux restarts: nothing takes the socket, so the page's connect fails and it retries.
      if (downMode === "down" && Date.now() < downUntil) {
        load.refused += 1;
        return new Response("acpmux is restarting", { status: 503 });
      }
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open() {
        load.socketOpenedAt ||= Date.now();
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        const result = answer(message.method, message.params);
        const reply = () => {
          if (message.method === "initialize") load.initializeAnsweredAt ||= Date.now();
          if (message.method === "_acpmux/attach") load.attachAnsweredAt ||= Date.now();
          // A socket the page gave up on meanwhile takes nothing.
          try {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          } catch {
            // Closed: the page asks again on its next socket.
          }
        };
        // A slow daemon: the socket is up but its handshake answers only once acpmux is ready.
        const delay = message.method === "initialize" && downMode === "slow-init" ? downUntil - Date.now() : 0;
        // fixed-wait: the slow daemon's answer time is the condition this mode measures; stops with the run.
        if (delay > 0) {
          const timer = setTimeout(() => {
            delayedReplies.delete(timer);
            reply();
          }, delay);
          delayedReplies.add(timer);
        } else reply();
      },
    },
  });
  releases.push([
    "stand-in acpmux",
    () => {
      for (const timer of delayedReplies) clearTimeout(timer);
      delayedReplies.clear();
      return daemon.stop(true);
    },
  ]);

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "first-load-bench-"));
  releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const work = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "first-load-bench-work-"));
  releases.push(["bundles", () => fs.rmSync(work, { recursive: true, force: true })]);
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
  const bundle = async (entry: string): Promise<string> => {
    const built = await Bun.build({ entrypoints: [entry], format: "iife", target: "browser" });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    return await built.outputs[0]!.text();
  };
  // The copy's boot script, as build-agent-pane-web.sh bundles it (chat-snapshot.js), and the writer the
  // warm page runs once settled (test/agent-pane-chat-snapshot.test.ts bundles it the same way).
  const bootScript = await bundle(path.join(chatSnapshotSource, "boot.ts"));
  const captureEntry = path.join(work, "capture-entry.ts");
  fs.writeFileSync(
    captureEntry,
    `import { captureMiss, captureSnapshot } from ${JSON.stringify(path.join(chatSnapshotSource, "capture.ts"))};\n` +
      "Object.assign(globalThis, { captureMiss, captureSnapshot });\n",
  );
  const captureScript = await bundle(captureEntry);

  // The page as the app serves it (build-agent-pane-web.sh): every sheet in one `<style id="cmux-pane-styles">`,
  // which the copy draws under and the writer leaves out of the copy, and after `<main id="root">` the
  // host's snapshot (async) and the script that draws it, before the module. Vite's own build links its
  // sheets instead; a lazy chunk's sheet comes later, so every sheet of the build goes in, linked ones first.
  let index = fs.readFileSync(path.join(out, "index.html"), "utf8");
  const linked: string[] = [];
  index = index.replace(/<link\b[^>]*\brel="stylesheet"[^>]*>/g, (tag) => {
    const href = /\bhref="([^"]+)"/.exec(tag)?.[1];
    if (href) linked.push(href.replace(/^\.?\//, ""));
    return "";
  });
  const assets = fs.existsSync(path.join(out, "assets")) ? fs.readdirSync(path.join(out, "assets")) : [];
  const sheets = [
    ...linked,
    ...assets
      .filter((name) => name.endsWith(".css"))
      .map((name) => `assets/${name}`)
      .filter((name) => !linked.includes(name))
      .sort(),
  ];
  if (sheets.length === 0) throw new Error("the pane build has no stylesheet");
  const css = sheets
    .map((sheet) =>
      // A sheet's relative url() names a file beside it; inline, it resolves from the page.
      fs
        .readFileSync(path.join(out, sheet), "utf8")
        .replace(
          /url\((["']?)(?![a-z]+:|\/|#)([^"')]+)\1\)/gi,
          (_match, quote: string, file: string) =>
            `url(${quote}/${path.posix.join(path.posix.dirname(sheet), file)}${quote})`,
        ),
    )
    .join("\n");
  if (/<\/style/i.test(css)) throw new Error("a pane sheet closes the page's <style>");
  // Each inlined sheet keeps an inert link of its href, so vite's preload helper finds it there and
  // links none of them again after the page's own sheet (the app's bundle links none): a sheet linked
  // late wins rules the page sheet's order lost them (a 48 px quiet composer row instead of 28).
  const placeholders = sheets.map((sheet) => `<link rel="stylesheet" media="not all" href="/${sheet}">`).join("\n");
  index = index.replace("</head>", () => `<style id="${PAGE_STYLE_ID}">\n${css}\n</style>\n${placeholders}\n</head>`);
  const ROOT = /<main id="root"><\/main>/;
  if (!ROOT.test(index)) throw new Error('the pane build has no <main id="root"></main>');
  index = index.replace(
    ROOT,
    () =>
      '<main id="root"></main>\n<script async src="/__snapshot/chat.js"></script>\n<script src="/chat-snapshot.js"></script>',
  );

  /// The copy the host serves this load (`__snapshot/chat.js`): null on the warm load, as with none kept.
  let servedCopy: ChatSnapshot | null = null;
  const script = (body: string) =>
    new Response(body, { headers: { "Content-Type": "text/javascript", "Cache-Control": "no-store" } });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      if (pathname === "/" || pathname === "/index.html")
        return new Response(index, { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
      // As the page host answers it (AgentPageResources.swift): the globals, then the boot if it ran first.
      if (pathname === "/__snapshot/chat.js")
        return script(
          `self.${SNAPSHOT_GLOBAL}=${JSON.stringify(servedCopy)};self.${SNAPSHOT_THEME_GLOBAL}=${JSON.stringify(THEME)};self.${SNAPSHOT_BOOT_GLOBAL}?.();`,
        );
      if (pathname === "/chat-snapshot.js") return script(bootScript);
      const file = Bun.file(path.join(out, pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser: Browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
    headless: true,
  });
  releases.push(["browser", () => browser.close()]);

  const prepare = async (page: Page, tail: unknown, windowMs: number) => {
    await installPaintedFrames(page);
    await page.addInitScript(installHost, { tail });
    await page.addInitScript(recordFrames, { windowMs, latest: LATEST, hostTag: SNAPSHOT_HOST_TAG });
  };

  /// TRACE=1: the boxes in the page's bottom band (from the composer's top down), by class, so a composer
  /// that sits elsewhere in the copy than on the live page names what stands under or over it.
  const bottomBand = () => {
    const composer = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect();
    if (!composer) return ["no composer"];
    const from = composer.top - 40;
    return [...document.querySelectorAll("#root *")]
      .map((element) => ({ element, box: element.getBoundingClientRect() }))
      .filter(({ box }) => box.height > 0 && box.bottom > from && box.height < 200)
      .slice(0, 60)
      .map(
        ({ element, box }) =>
          `${element.tagName.toLowerCase()}.${String(element.className).split(" ").slice(0, 2).join(".")} ${box.top.toFixed(0)}+${box.height.toFixed(0)}`,
      );
  };

  /// The load before the restart: acpmux up, the chat opened and settled, then its copy written as the
  /// page writes it (chatSnapshot/live.ts `watchChatSnapshot`).
  const warm = async (): Promise<ChatSnapshot> => {
    servedCopy = null;
    downMode = undefined;
    downUntil = 0;
    const context = await browser.newContext({ viewport: VIEWPORT });
    try {
      const page = await context.newPage();
      await prepare(page, null, 120_000);
      await page.goto(url);
      await page.waitForFunction(
        (quietMs) => {
          const recording = (window as unknown as BenchWindow).__firstLoad;
          return (
            recording.latestAt > 0 && performance.now() - Math.max(recording.latestAt, recording.changedAt) > quietMs
          );
        },
        SETTLE_QUIET_MS,
        { timeout: 120_000, polling: 100 },
      );
      await page.addScriptTag({ content: captureScript });
      const written = await page.evaluate((theme) => {
        const w = window as unknown as BenchWindow;
        w.__firstLoad.stop();
        const snapshot = w.captureSnapshot(document, theme);
        return { snapshot: snapshot ?? null, miss: snapshot ? "" : w.captureMiss() };
      }, THEME);
      if (TRACE) console.log(`warm bottom band:\n  ${(await page.evaluate(bottomBand)).join("\n  ")}`);
      if (!written.snapshot) throw new Error(`the settled page wrote no copy: ${written.miss}`);
      return written.snapshot;
    } finally {
      await context.close();
    }
  };

  /// The load after the restart: a cold context, the copy and the kept tail served, acpmux unavailable
  /// for DOWN_MS from navigation in `mode`.
  const relaunch = async (mode: Mode, copy: ChatSnapshot): Promise<Round> => {
    servedCopy = copy;
    const context = await browser.newContext({ viewport: VIEWPORT });
    try {
      const page = await context.newPage();
      await prepare(page, keptTail, RECORD_MS);
      load = { refused: 0, socketOpenedAt: 0, initializeAnsweredAt: 0, attachAnsweredAt: 0 };
      downMode = mode;
      downUntil = Date.now() + DOWN_MS;
      const upAt = downUntil;
      await page.goto(url, { waitUntil: "commit" });
      await page.waitForFunction(() => (window as unknown as BenchWindow).__firstLoad.done, undefined, {
        timeout: RECORD_MS + 60_000,
        polling: 250,
      });
      if (TRACE) console.log(`${mode} relaunch bottom band:\n  ${(await page.evaluate(bottomBand)).join("\n  ")}`);
      const got = await page.evaluate(() => {
        const w = window as unknown as BenchWindow;
        return {
          frames: w.__firstLoad.frames,
          layoutShift: w.__firstLoad.layoutShift,
          origin: performance.timeOrigin,
          miss: w.__cmuxChatSnapshotMiss ?? null,
          shown: w.__cmuxChatSnapshotShown ?? null,
          tailAskedAt: w.__benchHost.tailAskedAt,
          liveLatestAt: w.__firstLoad.liveLatestAt,
        };
      });
      const since = (epoch: number) => (epoch ? epoch - got.origin : null);
      return {
        mode,
        metrics: classifyFrames(got.frames),
        frames: got.frames,
        liveLatestMs: got.liveLatestAt || null,
        layoutShift: got.layoutShift,
        copyShownMs: got.shown?.at ?? null,
        swapMs: got.shown?.swappedAt ?? null,
        copyMiss: got.miss,
        tailAskedMs: got.tailAskedAt || null,
        acpmuxUpMs: upAt - got.origin,
        refused: load.refused,
        socketOpenedMs: since(load.socketOpenedAt),
        initializeAnsweredMs: since(load.initializeAnsweredAt),
        attachAnsweredMs: since(load.attachAnsweredAt),
      };
    } finally {
      downMode = undefined;
      downUntil = 0;
      servedCopy = null;
      await context.close();
    }
  };

  const byMode = new Map<Mode, Round[]>(MODES.map((mode) => [mode, []]));
  for (let round = 0; round < ROUNDS; round += 1)
    // Each relaunch draws the copy its own warm load wrote; modes alternate order so drift hits each alike.
    for (const mode of round % 2 ? [...MODES].reverse() : MODES) {
      const copy = await warm();
      byMode.get(mode)!.push(await relaunch(mode, copy));
    }

  const ms = (value: number | null) => (value === null ? "-" : value.toFixed(0));
  const median = (values: number[]) =>
    values.length ? [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]! : null;
  const max = (values: number[]) => (values.length ? Math.max(...values) : null);
  const numbers = (rounds: Round[], pick: (round: Round) => number | null) =>
    rounds.map(pick).filter((value): value is number => value !== null);
  const PICKS = {
    blankAfterContent: (r: Round) => r.metrics.blankAfterContent,
    shiftFrames: (r: Round) => r.metrics.shiftFrames,
    finalFirstPaintMs: (r: Round) => r.metrics.finalFirstPaintMs,
    firstContentMs: (r: Round) => r.metrics.firstContentMs,
    layoutShift: (r: Round) => r.layoutShift,
    frames: (r: Round) => r.metrics.frames,
  } as const;
  const json: Record<string, unknown> = { turns: TURNS, downMs: DOWN_MS, recordMs: RECORD_MS, rounds: ROUNDS };
  let failed = false;
  for (const [mode, rounds] of byMode) {
    console.log(
      `first-load-after-restart [${mode}]: ${TURNS} turns, acpmux unavailable ${DOWN_MS} ms from navigation, recorded ${RECORD_MS} ms, ${rounds.length} rounds`,
    );
    console.log(
      "round | blank after content | shift frames | final first paint ms | first content ms | layout shift | frames | copy drawn ms | swap ms | tail asked ms | acpmux up ms | refused | socket ms | initialize ms | attach ms",
    );
    rounds.forEach((r, at) =>
      console.log(
        [
          at + 1,
          r.metrics.blankAfterContent,
          r.metrics.shiftFrames,
          ms(r.metrics.finalFirstPaintMs),
          ms(r.metrics.firstContentMs),
          r.layoutShift.toFixed(4),
          r.metrics.frames,
          r.copyShownMs === null ? `none (${r.copyMiss ?? "?"})` : ms(r.copyShownMs),
          ms(r.swapMs),
          ms(r.tailAskedMs),
          ms(r.acpmuxUpMs),
          r.refused,
          ms(r.socketOpenedMs),
          ms(r.initializeAnsweredMs),
          ms(r.attachAnsweredMs),
        ].join(" | "),
      ),
    );
    const summary = (of: (values: number[]) => number | null) =>
      Object.fromEntries(Object.entries(PICKS).map(([key, pick]) => [key, of(numbers(rounds, pick))]));
    const medians = summary(median);
    const maxima = summary(max);
    for (const [label, values] of [
      ["median", medians],
      ["max", maxima],
    ] as const)
      console.log(
        [
          label,
          ...(["blankAfterContent", "shiftFrames", "finalFirstPaintMs", "firstContentMs"] as const).map((key) =>
            ms(values[key] ?? null),
          ),
          (values.layoutShift ?? 0).toFixed(4),
        ].join(" | "),
      );
    for (const r of rounds) if (r.copyShownMs === null) console.log(`  warning: a round drew no copy (${r.copyMiss})`);
    // A round that never handed over to the live chat proves nothing: a copy held over the whole
    // recording paints no blank and no shift.
    for (const r of rounds)
      if (r.liveLatestMs === null) console.log("  failed: the live chat never showed the newest answer");
    const bad = rounds.filter(
      (r) => r.metrics.blankAfterContent > 0 || r.metrics.shiftFrames > 0 || r.liveLatestMs === null,
    );
    if (bad.length > 0) failed = true;
    if (TRACE) {
      const score = (r: Round) => r.metrics.blankAfterContent + r.metrics.shiftFrames;
      const worst = [...rounds].sort(
        (a, b) => score(b) - score(a) || (b.metrics.finalFirstPaintMs ?? 0) - (a.metrics.finalFirstPaintMs ?? 0),
      )[0];
      if (worst) {
        console.log(`trace of the worst ${mode} round (ms from navigation; B blank after content, S shift):`);
        const shifts = new Map(worst.metrics.shiftAt.map(({ index, why }) => [index, why]));
        const blanks = new Set(worst.metrics.blankAt);
        worst.frames.forEach((frame, at) => {
          const bottom = frame.rows.at(-1);
          const layer = frame.copyShown ? "copy" : frame.rootHidden ? "hid " : "live";
          const marks = `${blanks.has(at) ? "B" : " "}${shifts.has(at) ? "S" : " "}`;
          const composer = frame.composer
            ? `${frame.composer.top.toFixed(1)}+${frame.composer.height.toFixed(1)}`
            : "-";
          console.log(
            [
              `  ${frame.t.toFixed(0).padStart(6)} ${layer} ${marks} rows ${String(frame.rows.length).padStart(2)}`,
              `bottom ${bottom ? `${bottom.id}@${bottom.top.toFixed(1)}` : "-"} "${frame.bottomText}"`,
              `composer ${composer}`,
              `scrollTop ${frame.scrollTop === null ? "-" : frame.scrollTop.toFixed(0)}`,
              ...(shifts.has(at) ? [shifts.get(at)!] : []),
            ].join(" | "),
          );
        });
      }
    }
    json[mode] = {
      rounds: rounds.map(({ frames: _frames, metrics: { blankAt: _blankAt, shiftAt, ...metrics }, ...rest }) => ({
        ...rest,
        ...metrics,
        shifts: shiftAt.slice(0, 20),
      })),
      median: medians,
      max: maxima,
    };
    const row = mode.replace("-", "_");
    for (const [metric, key, unit] of [
      ["blank_after_content", "blankAfterContent", "count"],
      ["shift_frames", "shiftFrames", "count"],
      ["final_first_paint", "finalFirstPaintMs", "ms"],
    ] as const)
      perfRow({
        name: `first_load_after_restart.${row}.${metric}`,
        p50: medians[key] ?? 0,
        p95: maxima[key] ?? 0,
        unit,
      });
  }
  console.log(`FIRST_LOAD_JSON ${JSON.stringify(json)}`);
  if (GATE && failed) {
    console.error("first-load-after-restart: a round blanked the chat after it showed content or moved it (GATE=1)");
    process.exitCode = 1;
  }
} finally {
  await release();
}
