// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A turn's end fold never reads the rows' geometry right after its own writes (hq docs/design/chat-
// render-pipeline.md, stage 5, R2/R9; Leo, 2026-11-16: "The rendering wants to recalculating stuff
// when the agent chat stream is going/ends, but text comes in pretty quickly, and stuff shifts at
// the bottom pretty frequently, and then there's a big wave of stuff that gets redrawn").
//
// The real pane (`?mock`) with a 700-turn chat (`cmuxAcpmuxDebug.loadSeed`), then one turn streamed
// with tool calls (`loadRun`) so its end folds. The gate: no geometry read from turnEndFold.ts
// follows an animation it started in the same script (each such read forces a style pass inside
// the script). Reported with it, from Chromium's trace from the fold's start to its end (at most a second): each
// style pass's element count (UpdateLayoutTree elementCount) against the thread's, the style and
// layout passes script forced, and the fold's own counters (turnEndFold.ts `turnEndFoldPerf`).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type TraceEvent = { name: string; ph: string; ts: number; dur?: number; tid: number; args?: any };

await requireBrowserLane("turn-end-fold-restyle.browser.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a turn's end fold restyles and forces layout only for the rows that fold", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(700))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    // The fold's start, stamped into the trace, with the thread's size then.
    await page.evaluate(() => {
      const w = window as any;
      w.__fold = { started: 0, threadElements: 0, rows: 0 };
      new MutationObserver(() => {
        const thread = document.querySelector(".acpmux-thread");
        if (!thread?.hasAttribute("data-turn-end-folding") || w.__fold.started) return;
        console.timeStamp("turn-end-fold-start");
        w.__fold.started = performance.now();
        w.__fold.threadElements = thread.querySelectorAll("*").length;
        w.__fold.rows = thread.querySelectorAll(":scope > .acpmux-row[data-row-id]").length;
      }).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["data-turn-end-folding"] });
      // A read after a write (R2) inside one pass of the fold: an animation the fold starts dirties
      // style, and a geometry read of the transcript before that pass ends forces a style pass inside
      // the script, once per row when reads and writes interleave. A pass ends with the script that
      // ran it (a microtask after it) or when the next one starts: each mutation callback and scroll
      // listener starts clean. `readsAfterWrite` counts every transcript read after any thread
      // animation while the fold plays (other code's too), for the report only.
      w.__r2 = {
        writes: 0,
        readsAfterWrite: 0,
        foldReadsAfterWrite: 0,
        byFunction: {} as Record<string, number>,
      };
      let dirty = false;
      let foldDirty = false;
      const clean = () => {
        dirty = false;
        foldDirty = false;
      };
      const folding = () => Boolean(document.querySelector(".acpmux-thread[data-turn-end-folding]"));
      const inTranscript = (node: unknown) => node instanceof Element && Boolean(node.closest(".acpmux-scroll"));
      const fromFold = () => /turnEndFold/.test(new Error().stack ?? "");
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (this: Element, ...args: Parameters<Element["animate"]>) {
        if (this.closest(".acpmux-thread")) {
          if (!dirty && !foldDirty) queueMicrotask(clean);
          dirty = true;
          if (fromFold()) {
            w.__r2.writes += 1;
            foldDirty = true;
          }
        }
        return animate.apply(this, args);
      };
      const Observer = window.MutationObserver;
      window.MutationObserver = class extends Observer {
        constructor(callback: MutationCallback) {
          super((records, observer) => {
            clean();
            callback(records, observer);
          });
        }
      };
      const listeners = new WeakMap<object, EventListener>();
      const add = EventTarget.prototype.addEventListener;
      const remove = EventTarget.prototype.removeEventListener;
      EventTarget.prototype.addEventListener = function (
        this: EventTarget,
        type: string,
        listener: any,
        options?: any,
      ) {
        if (type !== "scroll" || typeof listener !== "function") return add.call(this, type, listener, options);
        const wrapped: EventListener = (event) => {
          clean();
          listener.call(this, event);
        };
        listeners.set(listener, wrapped);
        return add.call(this, type, wrapped, options);
      };
      EventTarget.prototype.removeEventListener = function (
        this: EventTarget,
        type: string,
        listener: any,
        options?: any,
      ) {
        return remove.call(this, type, (listener && listeners.get(listener)) ?? listener, options);
      };
      const countRead = (node: unknown) => {
        if (!dirty || !inTranscript(node)) return;
        if (foldDirty && fromFold()) {
          w.__r2.foldReadsAfterWrite += 1;
          // Which of the fold's functions read: its innermost frame in turnEndFold.ts.
          const stack = new Error().stack ?? "";
          const at = /at (?:Object\.)?([\w$.]+) \([^)]*turnEndFold[^)]*\)/.exec(stack)?.[1] ?? "?";
          w.__r2.byFunction[at] = (w.__r2.byFunction[at] ?? 0) + 1;
        }
        if (folding()) w.__r2.readsAfterWrite += 1;
      };
      for (const [proto, name] of [
        [HTMLElement.prototype, "offsetHeight"],
        [HTMLElement.prototype, "offsetTop"],
        [HTMLElement.prototype, "offsetWidth"],
        [Element.prototype, "clientHeight"],
        [Element.prototype, "scrollTop"],
        [Element.prototype, "scrollHeight"],
      ] as const) {
        const descriptor = Object.getOwnPropertyDescriptor(proto, name)!;
        Object.defineProperty(proto, name, {
          ...descriptor,
          get(this: Element) {
            countRead(this);
            return descriptor.get!.call(this);
          },
        });
      }
      const rect = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = function (this: Element) {
        countRead(this);
        return rect.call(this);
      };
      const computed = window.getComputedStyle.bind(window);
      window.getComputedStyle = (node: Element, pseudo?: string | null) => {
        countRead(node);
        return computed(node, pseudo);
      };
    });
    await page.evaluate(async () => {
      const fold = await import("/conversation/turnEndFold.ts" as string);
      fold.resetTurnEndFoldPerf?.();
    });
    await browser!.startTracing(page, {
      categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"],
    });
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 2,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 12,
        scroll_speed: 0,
      }),
    )) as Record<string, any>;
    // The fold has started and ended (its attribute set, then gone), and two frames have painted since.
    await page.waitForFunction(
      () => (window as any).__fold.started > 0 && !document.querySelector(".acpmux-thread[data-turn-end-folding]"),
      null,
      { timeout: 10_000 },
    );
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const fold = (await page.evaluate(() => (window as any).__fold)) as {
      started: number;
      threadElements: number;
      rows: number;
    };
    const r2 = (await page.evaluate(() => (window as any).__r2)) as {
      writes: number;
      readsAfterWrite: number;
      foldReadsAfterWrite: number;
      byFunction: Record<string, number>;
    };
    // The fold's own counters (turnEndFold.ts `turnEndFoldPerf`), from the module the pane runs.
    const passes = (await page.evaluate(async () => {
      const fold = await import("/conversation/turnEndFold.ts" as string);
      return fold.turnEndFoldPerf ? { ...fold.turnEndFoldPerf } : null;
    })) as Record<string, number> | null;
    const raw = JSON.parse((await browser!.stopTracing()).toString()) as { traceEvents: TraceEvent[] };
    await page.close();
    expect(run.error).toBeUndefined();
    expect(fold.started, "the turn's end folded").toBeGreaterThan(0);
    const stamp = raw.traceEvents.find(
      (event) => event.name === "TimeStamp" && event.args?.data?.message === "turn-end-fold-start",
    );
    expect(stamp, "the fold's start is in the trace").toBeDefined();
    const from = stamp!.ts - 50_000;
    const to = stamp!.ts + 1_000_000;
    const inFold = raw.traceEvents.filter((event) => event.ts >= from && event.ts <= to && event.ph === "X");
    const recalcs = inFold.filter((event) => event.name === "UpdateLayoutTree");
    const elements = recalcs.map((event) => Number(event.args?.elementCount ?? event.args?.data?.elementCount ?? 0));
    // A style or layout pass script forced: one inside a script task on the same thread.
    const scripts = inFold.filter((event) =>
      [
        "FunctionCall",
        "EvaluateScript",
        "RunMicrotasks",
        "V8.RunMicrotasks",
        "TimerFire",
        "FireAnimationFrame",
        "EventDispatch",
      ].includes(event.name),
    );
    const forced = (name: string) =>
      inFold.filter(
        (event) =>
          event.name === name &&
          scripts.some(
            (script) =>
              script.tid === event.tid &&
              script.ts <= event.ts &&
              script.ts + (script.dur ?? 0) >= event.ts + (event.dur ?? 0),
          ),
      ).length;
    const report = {
      threadElements: fold.threadElements,
      mountedRows: fold.rows,
      recalcs: recalcs.length,
      maxElements: Math.max(0, ...elements),
      totalElements: elements.reduce((a, b) => a + b, 0),
      overHalf: elements.filter((count) => count > fold.threadElements / 2).length,
      forcedStyle: forced("UpdateLayoutTree"),
      forcedLayout: forced("Layout"),
      foldWrites: r2.writes,
      readsAfterWrite: r2.readsAfterWrite,
      foldReadsAfterWrite: r2.foldReadsAfterWrite,
      foldReadsByFunction: r2.byFunction,
      passes,
    };
    console.log(`TURN-END-FOLD-RESTYLE ${JSON.stringify(report)}`);
    expect(report.foldWrites, "the fold animated rows").toBeGreaterThan(0);
    // `overHalf` is reported, not gated: the one or two passes over 1,500+ elements a turn's end can
    // draw cover the whole pane (more elements than the thread holds) on base and head alike, in
    // some seeds, so they are not the fold's.
    // Each pass reads every place first and writes after (R2): no geometry read of the transcript
    // follows an animation the fold started in the same script, so no row's write forces a style pass.
    expect(report.foldReadsAfterWrite, "the fold's geometry reads after its own write in the same script").toBe(0);
  });
});
