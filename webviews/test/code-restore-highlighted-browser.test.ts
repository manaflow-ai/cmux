// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat opened after a relaunch never shows a code card it already showed highlighted as plain text
// first: the relaunch's copy of the chat (chatSnapshot/) drew it highlighted, and the live page took
// over from the copy before its code cards' chunk had loaded (App.tsx loads it after first paint),
// so every fence on screen went plain, then colored again (Leo, 2026-11-22, after a relaunch to
// update: "and then more shit re-rendered. all of these need fucking help").
//
// The real pane as it ships (vite.config.acpmux-pane.mjs, production React) with Pierre's worker as
// a module worker (devHighlightWorker.ts), against a stand-in acpmux over a WebSocket: a long chat
// whose every reply ends in a TypeScript fence, opened on its latest page under a copy that shows
// highlighted code (the boot script's copy: a shadow-root host over the live root at opacity 0, as
// chatSnapshot/paint.ts leaves it). From the frame the copy goes, counted frame by frame: code cards
// on screen drawing plain lines, and plain cards swapped for highlighted ones.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/code-restore-highlighted-browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { loadTurn, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { devHighlightWorker } from "./support/devHighlightWorker";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("code-restore-highlighted-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("code-restore-highlighted-browser", "chromium", chromium))) {
    describe.skip("restored code draws highlighted", () => test("chromium", () => {}));
    return;
  }
  setDefaultTimeout(400_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const SESSION = "0190a000-0000-7000-8000-0000000000c6";
  const TURNS = 120;
  const ATTACH_LIMIT = 40;
  const base = 1_791_000_000_000;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/mock/project",
    title: "Long chat",
    harness: "claude",
    status: "idle",
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: TURNS,
    createdAt: base,
    updatedAt: base + TURNS * 60_000,
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>, at: number) =>
    void events.push({ sessionId: SESSION, seq: events.length + 1, at, dir, kind, msg });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: `agent-${SESSION}`, update: body },
  });
  const prompts: number[] = [];
  const recordStep = (step: LoadStep, turn: number, at: number) => {
    if ("update" in step) record("in", String(step.update.sessionUpdate), update(step.update), at);
    else if (step.mux === "user_message") {
      record("mux", "user_message", { ...step.msg, promptId: `p-${turn}` }, at);
      prompts.push(events.length);
    } else if (step.mux === "turn_started")
      record("mux", "turn_started", { turnId: `t-${turn}`, promptId: `p-${turn}` }, at);
    else record("mux", step.mux, step.msg ?? {}, at);
  };
  for (let turn = 0; turn < TURNS; turn++)
    for (const step of loadTurn(turn, { diffLines: 20, logLines: 20 })) recordStep(step, turn, base + turn * 60_000);

  const page = (params: Record<string, any>, attach: boolean) => {
    const kinds: string[] = Array.isArray(params.kinds) ? params.kinds : [];
    const transcript = (event: Event) =>
      kinds.length === 0 ||
      kinds.includes(event.kind) ||
      (kinds.includes("transcript") && event.kind !== "available_commands_update");
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const asked = params.limit === undefined ? Infinity : Math.max(1, Number(params.limit));
    const limit = attach ? Math.min(asked, ATTACH_LIMIT) : asked;
    const maxBytes = params.maxBytes === undefined ? Infinity : Number(params.maxBytes);
    const out: Event[] = [];
    let bytes = 0;
    let hasMore = false;
    const take = (event: Event) => {
      if (event.seq <= after || event.seq >= before || !transcript(event)) return true;
      if (out.length >= limit) return !(hasMore = true);
      bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
      if (out.length > 0 && bytes > maxBytes) return !(hasMore = true);
      out.push(event);
      return true;
    };
    if (newest) {
      for (let i = events.length - 1; i >= 0 && take(events[i]!); i -= 1);
      out.reverse();
    } else for (let i = 0; i < events.length && take(events[i]!); i += 1);
    return { events: out, hasMore };
  };
  const turnOpener = (first: Event | undefined, hasMore: boolean) => {
    const opens = (event: Event) => event.dir === "mux" && event.kind === "user_message";
    if (!hasMore || !first || first.seq <= 1 || opens(first)) return null;
    for (let i = first.seq - 2; i >= 0; i -= 1) if (opens(events[i]!)) return events[i]!;
    return null;
  };
  const asked = new Map<string, number>();
  function answer(method: string, params: Record<string, any>): unknown {
    asked.set(method, (asked.get(method) ?? 0) + 1);
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach": {
        const p = page(params, true);
        return {
          session: summary(),
          ...p,
          lastSeq: events.length,
          pageThrough: events.length,
          turnOpener: turnOpener(p.events[0], p.hasMore),
        };
      }
      case "_acpmux/events":
        return { ...page(params, false), lastSeq: events.length };
      default:
        return null;
    }
  }

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "code-restore-highlighted-"));
  let statics: ReturnType<typeof Bun.serve> | undefined;
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      // The app's page starts Pierre's worker from its bundled highlight-worker.js; this one runs
      // Pierre's own worker as a module worker, so code cards highlight as in the app.
      plugins: [devHighlightWorker()],
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open() {},
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          ws.send(
            JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
          );
        },
      },
    });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await statics?.stop(true);
    await daemon?.stop(true);
    fs.rmSync(out, { recursive: true, force: true });
  });
  const url = () =>
    `http://127.0.0.1:${statics!.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon!.port}/`)}&token=t&session=${SESSION}`;

  type Report = {
    /// Page time of the first painted frame whose live root shows rows (under the copy).
    liveFirstRowsMs: number;
    /// Page time the copy went.
    swapMs: number;
    /// Frames after the swap until quiet.
    frames: number;
    /// Code cards on screen in the first frame after the swap, and how many of them drew plain lines.
    cardsAtSwap: number;
    plainAtSwap: number;
    /// Frames after the swap with a plain-drawn code card on screen.
    plainFrames: number;
    /// Plain cards or plain lines taken out of a code card on screen after the swap (plain -> highlighted).
    plainSwaps: number;
    /// Highlighted cards on screen at the end.
    highlightedAtEnd: number;
    loads: string[];
    workers: string[];
    firstHighlightedMs: number;
    swapMark: number;
  };

  /// Before the page's scripts: draws a copy as the boot script does (a `cmux-chat-snapshot` host whose
  /// shadow root shows a highlighted code card, over the live root at opacity 0), then watches the
  /// live root's code cards from the frame the copy goes.
  const watch = (p: Page, lateMs: number) =>
    p.addInitScript((late: number) => {
      const w = window as any;
      // Pierre's worker answers its first jobs late, as one started while the app is still busy
      // launching does: what it is sent in its first `late` ms reaches it then.
      const RealWorker: any = window.Worker;
      const LateWorker = function (...args: any[]) {
        const worker = new RealWorker(...args);
        const born = performance.now();
        (w.__workers ??= []).push(`${String(args[0]).split("/").pop()}@${Math.round(born)}`);
        const post = worker.postMessage.bind(worker);
        worker.postMessage = (...message: any[]) => {
          const wait = born + late - performance.now();
          if (wait > 0) setTimeout(() => post(...message), wait);
          else post(...message);
        };
        return worker;
      };
      LateWorker.prototype = RealWorker.prototype;
      w.Worker = LateWorker;
      const state = {
        liveFirstRowsMs: 0,
        swapMs: 0,
        frames: 0,
        cardsAtSwap: -1,
        plainAtSwap: -1,
        plainFrames: 0,
        plainSwaps: 0,
      };
      w.__codeState = state;
      const drawCopy = () => {
        const root = document.getElementById("root");
        if (!root || document.querySelector("cmux-chat-snapshot")) return;
        const host = document.createElement("cmux-chat-snapshot");
        host.setAttribute("inert", "");
        host.style.cssText = "position:fixed;inset:0;display:block;pointer-events:none;background:#111";
        host.attachShadow({ mode: "open" }).innerHTML =
          '<div class="cv-codeblock"><diffs-container></diffs-container></div>';
        document.body.appendChild(host);
        root.style.opacity = "0";
        w.__cmuxChatSnapshotShown = { at: performance.now() };
      };
      document.addEventListener("readystatechange", () => {
        if (document.readyState === "interactive") drawCopy();
      });
      const onScreen = (node: Element) => {
        const box = node.getBoundingClientRect();
        return box.height > 0 && box.bottom > 0 && box.top < innerHeight;
      };
      const plainCard = (card: Element) =>
        card.classList.contains("cv-codeblock--plain") ||
        [...card.querySelectorAll<HTMLElement>("pre.cv-code-plain")].some(
          (pre) => getComputedStyle(pre).visibility !== "hidden" && pre.getBoundingClientRect().height > 0,
        );
      const cards = () => [...document.querySelectorAll("#root .cv-codeblock")].filter(onScreen);
      let observer: MutationObserver | undefined;
      const begin = () => {
        state.swapMs = Math.round(performance.now());
        observer = new MutationObserver((list) => {
          for (const change of list)
            for (const gone of change.removedNodes)
              if (
                gone instanceof Element &&
                (gone.matches(".cv-codeblock--plain, pre.cv-code-plain") ||
                  gone.querySelector(".cv-codeblock--plain, pre.cv-code-plain")) &&
                change.target instanceof Element &&
                change.target.isConnected &&
                onScreen(change.target)
              )
                state.plainSwaps += 1;
        });
        observer.observe(document.getElementById("root")!, { subtree: true, childList: true });
      };
      const loop = () =>
        w.cmuxAfterPaint(() => {
          const shown = cards();
          if (!state.swapMs && !w.__firstHighlightedMs && shown.some((card) => !plainCard(card)))
            w.__firstHighlightedMs = Math.round(performance.now());
          if (!state.liveFirstRowsMs && document.querySelector("#root article.acpmux-row"))
            state.liveFirstRowsMs = Math.round(performance.now());
          if (!state.swapMs) {
            if (state.liveFirstRowsMs && !document.querySelector("cmux-chat-snapshot")) begin();
            else return;
          }
          state.frames += 1;
          const plain = shown.filter(plainCard).length;
          if (state.cardsAtSwap < 0) {
            state.cardsAtSwap = shown.length;
            state.plainAtSwap = plain;
          }
          if (plain > 0) state.plainFrames += 1;
          if (!w.__firstHighlightedMs && shown.some((card) => !plainCard(card)))
            w.__firstHighlightedMs = Math.round(performance.now());
        });
      const wait = () => (typeof w.cmuxAfterPaint === "function" ? loop() : setTimeout(wait, 0));
      wait();
      w.__codeReport = () => {
        observer?.disconnect();
        const highlightedAtEnd = cards().filter((card) => !plainCard(card)).length;
        const { liveFirstRowsMs, swapMs, frames, cardsAtSwap, plainAtSwap, plainFrames, plainSwaps } = state;
        // When the code cards' chunks and Pierre's worker were asked for, in page time.
        const loads = performance
          .getEntriesByType("resource")
          .map((entry) => entry as PerformanceResourceTiming)
          .filter((entry) => /Highlighted|worker/i.test(entry.name))
          .map(
            (entry) => `${entry.name.split("/").pop()}@${Math.round(entry.startTime)}-${Math.round(entry.responseEnd)}`,
          );
        return {
          liveFirstRowsMs,
          swapMs,
          frames,
          cardsAtSwap,
          plainAtSwap,
          plainFrames,
          plainSwaps,
          highlightedAtEnd,
          loads,
          workers: w.__workers ?? [],
          firstHighlightedMs: w.__firstHighlightedMs ?? 0,
          swapMark: Math.round(performance.getEntriesByName("cmux-chat:snapshot-swap")[0]?.startTime ?? 0),
        };
      };
    }, lateMs);

  const LATE_MS = Number(process.env.CODE_RESTORE_LATE_MS ?? 1000);
  const run = async (): Promise<Report> => {
    const context = await browser!.newContext({ viewport: { width: 1200, height: 900 } });
    try {
      // A relaunch's page loads its later chunks while the app is still busy launching: each comes
      // LATE_MS late, as a busy launch's loader serves them.
      await context.route(/\/assets\/Highlighted[^/]*\.js$/, async (route) => {
        await new Promise((done) => setTimeout(done, LATE_MS));
        await route.continue();
      });
      const p = await context.newPage();
      await installPaintedFrames(p);
      await watch(p, LATE_MS);
      await p.goto(url());
      await p.waitForFunction(() => (window as any).__codeState?.swapMs > 0, null, { timeout: 60_000 });
      // Two and a half seconds of frames after the copy went.
      await p.waitForFunction(() => performance.now() - (window as any).__codeState.swapMs > 2_500, null, {
        timeout: 30_000,
        polling: 100,
      });
      const report = (await p.evaluate(() => (window as any).__codeReport())) as Report;
      console.log(`code-restore relaunch: ${JSON.stringify({ ...report, asked: Object.fromEntries(asked) })}`);
      return report;
    } finally {
      await context.close();
    }
  };

  test("relaunch under a copy showing highlighted code: no card on screen draws plain after the copy goes", async () => {
    const report = await run();
    // The fixture's latest page shows fences, and they highlight.
    expect(report.cardsAtSwap).toBeGreaterThan(0);
    expect(report.highlightedAtEnd).toBeGreaterThan(0);
    expect(report.frames).toBeGreaterThan(10);
    expect({
      plainAtSwap: report.plainAtSwap,
      plainFrames: report.plainFrames,
      plainSwaps: report.plainSwaps,
    }).toEqual({ plainAtSwap: 0, plainFrames: 0, plainSwaps: 0 });
  });
});
