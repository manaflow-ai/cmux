// cmux-web-test-timeout: 900
// l10n-allow-file: typed fixture text, not shipped UI.
// The two height motions of the composer's column, read on every painted frame (paintedFrames.ts),
// in Chromium and WebKit, at rest and with a busy main thread (a 40 ms task every 70 ms, as a loaded
// Mac's page sees). Leo, 2026-11-11: "oof yeah there's some ultra bad looking slow animations when
// the composer goes up".
//
// - The prompt field growing and shrinking with its draft (composer/fieldGrowth.ts, gallery
//   agent-pane.composer-growth): a draft cleared, a typed wrap, a Shift-Return line, a long
//   insertion and a clear again.
// - The goal row of the composer hat opening and folding (TaskGoalStrip.tsx, gallery
//   agent-pane.composer-goal).
//
// Each input (a step) is measured the same way:
// - cost: the box and scroll reads the motion's own module makes (a stack names fieldGrowth.ts or
//   TaskGoalStrip.tsx), and in Chromium the page's layouts, style recalcs and long tasks;
// - stalls: frames between a motion's first and last move whose height did not move (the box
//   lagging its content), frames that moved against it, and blank frames (the field's caret line,
//   or the goal's first line, not drawn inside its box);
// - the motion's length, from the last frame before it moved to the last frame that moved;
// - jumps: the largest one-frame step against the line height, the composer card's bottom and the
//   goal's first line against its box (both should never move), and Chromium's layout-shift score.
//
// CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type CDPSession, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = { t: number; h: number; anchor: number; line: number; inside: boolean };
/** One input's motion: its moving frames, the still frames between its first and last move (the box
 *  lagging its content), frames that moved against it, its largest one-frame step, and its length
 *  from the input to the last frame that moved. */
type Run = { frames: number; stalls: number; back: number; maxStep: number; ms: number; from: number; to: number };
/** What one input cost the page (Chromium's own counters; null where the engine has none). */
type Cost = { reads: number; layouts: number | null; styles: number | null; longTasks: number | null };
type Report = {
  engine: string;
  lagging: boolean;
  line: number;
  runs: Run[];
  stalls: number;
  blank: number;
  back: number;
  maxStep: number;
  anchorShift: number;
  lineShift: number;
  layoutShift: number | null;
  costs: Cost[];
  totalMs: number;
};

await requireBrowserLane("composer-growth-frames.test.ts", async () => {
  setDefaultTimeout(840_000);
  const GROWTH = "agent-pane.composer-growth";
  const GOAL = "agent-pane.composer-goal";
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-growth-frames: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer growth frames", () => test("no engine", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, [GROWTH, GOAL], { browser: browsers.values().next().value });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /// The page side, before the app loads: counts the box and scroll reads whose stack names the
  /// motion's module, while `__reads.on`, outside the test's own frame reads (`__reads.probe`).
  const countReads = () => {
    const w = window as unknown as {
      __reads?: { on: boolean; probe: boolean; count: number; module: string };
    };
    if (w.__reads) return;
    const reads = { on: false, probe: false, count: 0, module: "" };
    w.__reads = reads;
    const note = () => {
      if (!reads.on || reads.probe) return;
      const limit = Error.stackTraceLimit;
      Error.stackTraceLimit = 60;
      const stack = new Error().stack ?? "";
      Error.stackTraceLimit = limit;
      if (stack.includes(reads.module)) reads.count += 1;
    };
    const method = (proto: object, name: string) => {
      const own = proto as Record<string, (...args: unknown[]) => unknown>;
      const original = own[name]!;
      own[name] = function (this: unknown, ...args: unknown[]) {
        note();
        return original.apply(this, args);
      };
    };
    const getter = (proto: object, name: string) => {
      const descriptor = Object.getOwnPropertyDescriptor(proto, name);
      if (!descriptor?.get) return;
      const get = descriptor.get;
      Object.defineProperty(proto, name, {
        ...descriptor,
        get(this: unknown) {
          note();
          return get.call(this);
        },
      });
    };
    method(Element.prototype, "getBoundingClientRect");
    method(Element.prototype, "getClientRects");
    for (const name of ["scrollHeight", "scrollWidth", "clientHeight", "clientWidth", "scrollTop"])
      getter(Element.prototype, name);
    for (const name of ["offsetHeight", "offsetWidth", "offsetTop"]) getter(HTMLElement.prototype, name);
  };

  async function open(engine: string, entry: string, variant: string, ready: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 640 } });
    await page.addInitScript(countReads);
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 760, theme: "dark" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(ready).waitFor({ timeout: 30_000 });
    await page.evaluate(() => {
      const w = window as unknown as { __shift: number; __long: number };
      w.__shift = 0;
      w.__long = 0;
      const types = PerformanceObserver.supportedEntryTypes ?? [];
      if (types.includes("layout-shift"))
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) w.__shift += (entry as unknown as { value: number }).value;
        }).observe({ type: "layout-shift" });
      if (types.includes("longtask"))
        new PerformanceObserver((list) => {
          w.__long += list.getEntries().length;
        }).observe({ type: "longtask" });
    });
    return page;
  }

  /// A busy main thread: a long task of `busy` ms every `every` ms.
  const lag = (page: Page, busy: number, every: number) =>
    page.evaluate(
      ([busy, every]) => {
        const w = window as unknown as { __lag: number };
        w.__lag = window.setInterval(() => {
          const until = performance.now() + busy;
          while (performance.now() < until) {
            /* busy */
          }
        }, every);
      },
      [busy, every] as const,
    );

  /// Starts reading every painted frame: the moving box's height, an anchor that must not move (the
  /// composer card's bottom: the stack grows upward), the goal's first line against its box's top,
  /// and whether the line the motion is for is drawn inside the box.
  const startFrames = (page: Page, which: "field" | "goal") =>
    page.evaluate((which) => {
      type Frame = { t: number; h: number; anchor: number; line: number; inside: boolean };
      const w = window as unknown as {
        __frames: Frame[];
        __marks: number[];
        __stop: () => void;
        __reads: { probe: boolean };
      };
      w.__frames = [];
      w.__marks = [];
      const round = (value: number) => Math.round(value * 100) / 100;
      const read = (t: number) => {
        w.__reads.probe = true;
        try {
          const card = document.querySelector<HTMLElement>(".acpmux-composer-box");
          if (!card) return;
          const anchor = round(card.getBoundingClientRect().bottom);
          if (which === "field") {
            const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field");
            if (!field) return;
            const box = field.getBoundingClientRect();
            const selection = getSelection();
            const range = selection && selection.rangeCount ? selection.getRangeAt(0) : undefined;
            const caret = range ? [...range.getClientRects()].at(-1) : undefined;
            // The caret's line drawn at least partly in the field (an empty draft's caret has no box).
            const inside = !caret || (caret.bottom > box.top + 1 && caret.top < box.bottom - 1);
            w.__frames.push({ t, h: round(box.height), anchor, line: 0, inside });
          } else {
            const clip = document.querySelector<HTMLElement>(".acpmux-goal-clip");
            const text = document.querySelector<HTMLElement>(".acpmux-goal-objective, .acpmux-goal-field");
            if (!clip || !text) return;
            const box = clip.getBoundingClientRect();
            const range = document.createRange();
            range.selectNodeContents(text);
            const first = range.getClientRects()[0] ?? text.getBoundingClientRect();
            // The objective's first line whole inside its box: a blank or clipped first line is not.
            const inside = first.top >= box.top - 0.5 && first.bottom <= box.bottom + 0.5;
            w.__frames.push({ t, h: round(box.height), anchor, line: round(first.top - box.top), inside });
          }
        } finally {
          w.__reads.probe = false;
        }
      };
      let on = true;
      w.__stop = () => (on = false);
      window.cmuxAfterPaint((t) => {
        read(t);
        return on;
      });
    }, which);

  const stopFrames = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as {
        __frames: Frame[];
        __marks: number[];
        __stop: () => void;
        __shift: number;
        __lag?: number;
      };
      w.__stop();
      if (w.__lag !== undefined) window.clearInterval(w.__lag);
      return { frames: w.__frames, marks: w.__marks, shift: w.__shift };
    });

  /// Until nothing in `selector` animates and two painted frames pass.
  const rest = async (page: Page, selector: string) => {
    await page.waitForFunction(
      (selector) => {
        const node = document.querySelector(selector);
        return !!node && node.getAnimations({ subtree: true }).filter((a) => a.playState === "running").length === 0;
      },
      selector,
      { timeout: 15_000 },
    );
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => window.cmuxPaintFrame());
  };

  /// Chromium's layout and style recalc counts, from its own counters.
  const counters = async (page: Page, cdp: CDPSession | undefined) => {
    if (!cdp) return undefined;
    const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
    const get = (name: string) => metrics.find((metric) => metric.name === name)?.value ?? 0;
    return { layouts: get("LayoutCount"), styles: get("RecalcStyleCount") };
  };

  /// Runs `act` as one step: marks where its frames start, counts the module's own layout reads,
  /// Chromium's layouts and style recalcs and long tasks, and waits for the motion to land.
  const step = async (
    page: Page,
    cdp: CDPSession | undefined,
    module: string,
    selector: string,
    act: () => Promise<void>,
  ): Promise<Cost> => {
    await page.evaluate((module) => {
      const w = window as unknown as {
        __reads: { on: boolean; count: number; module: string };
        __marks: number[];
        __frames: unknown[];
        __long: number;
        __longAt: number;
      };
      w.__reads.module = module;
      w.__reads.count = 0;
      w.__reads.on = true;
      w.__marks.push(w.__frames.length);
      w.__longAt = w.__long;
    }, module);
    const before = await counters(page, cdp);
    await act();
    await page.evaluate(() => window.cmuxPaintFrame());
    await rest(page, selector);
    const after = await counters(page, cdp);
    const { reads, long } = await page.evaluate(() => {
      const w = window as unknown as { __reads: { on: boolean; count: number }; __long: number; __longAt: number };
      w.__reads.on = false;
      return { reads: w.__reads.count, long: w.__long - w.__longAt };
    });
    return {
      reads,
      layouts: before && after ? after.layouts - before.layouts : null,
      styles: before && after ? after.styles - before.styles : null,
      longTasks: cdp ? long : null,
    };
  };

  /// Each step's frames (from its mark to the next) as one motion: the frames that moved, the still
  /// frames between its first and last move (a stall: the box lagging its content), frames that moved
  /// against the step's direction, the largest one-frame step, and the time from the last frame
  /// drawn before it moved to its last move.
  const analyse = (frames: Frame[], marks: number[], line: number) => {
    const runs: Run[] = [];
    for (let index = 0; index < marks.length; index++) {
      const slice = frames.slice(Math.max(0, marks[index]! - 1), marks[index + 1] ?? frames.length);
      if (slice.length < 2) continue;
      const moves: { at: number; step: number }[] = [];
      for (let i = 1; i < slice.length; i++) {
        const step = slice[i]!.h - slice[i - 1]!.h;
        if (Math.abs(step) >= 0.05) moves.push({ at: i, step });
      }
      if (moves.length === 0) continue;
      const first = moves[0]!.at;
      const last = moves.at(-1)!.at;
      const direction = Math.sign(slice[last]!.h - slice[first - 1]!.h);
      runs.push({
        frames: moves.length,
        stalls: last - first + 1 - moves.length,
        back: moves.filter((move) => Math.sign(move.step) !== direction).length,
        maxStep: Math.round(Math.max(...moves.map((move) => Math.abs(move.step))) * 100) / 100,
        ms: Math.round(slice[last]!.t - slice[first - 1]!.t),
        from: slice[first - 1]!.h,
        to: slice[last]!.h,
      });
    }
    const spread = (values: number[]) =>
      values.length ? Math.round((Math.max(...values) - Math.min(...values)) * 100) / 100 : 0;
    return {
      line,
      runs,
      stalls: runs.reduce((sum, run) => sum + run.stalls, 0),
      blank: frames.filter((frame) => !frame.inside).length,
      back: runs.reduce((sum, run) => sum + run.back, 0),
      maxStep: Math.max(0, ...runs.map((run) => run.maxStep)),
      anchorShift: spread(frames.map((frame) => frame.anchor)),
      lineShift: spread(frames.map((frame) => frame.line)),
      totalMs: runs.reduce((sum, run) => sum + run.ms, 0),
    };
  };

  const WRAP =
    "the client waits a little longer before each retry and adds random jitter so a crowd of clients does not retry in step";
  const LONG = Array.from(
    { length: 6 },
    (_, index) => `Line ${index + 1}: the client waits longer before each retry.`,
  ).join(" ");

  for (const [name] of engines)
    for (const lagging of [false, true]) {
      test(`${name}${lagging ? ", lagging" : ""}: the prompt field grows and shrinks with no stalled, blank or jumping frame`, async () => {
        const page = await open(name, GROWTH, "typed-wrap", ".acpmux-composer-box .acpmux-md-field");
        const cdp = name === "chromium" ? await page.context().newCDPSession(page) : undefined;
        await cdp?.send("Performance.enable");
        try {
          const box = ".acpmux-composer-box";
          await page.locator(".acpmux-composer-box .acpmux-md").click();
          await rest(page, box);
          const line = await page.evaluate(() =>
            Number.parseFloat(
              getComputedStyle(document.querySelector(".acpmux-composer-box .acpmux-md-field")!).lineHeight,
            ),
          );
          if (lagging) await lag(page, 40, 70);
          await startFrames(page, "field");
          const module = "composer/fieldGrowth.ts";
          const costs: Cost[] = [];
          const clear = async () => {
            await page.keyboard.press("ControlOrMeta+A");
            await page.keyboard.press("Backspace");
          };
          // Cleared, a typed wrap, a Shift-Return line, a long insertion, cleared again.
          costs.push(await step(page, cdp, module, box, clear));
          costs.push(await step(page, cdp, module, box, () => page.keyboard.type(WRAP, { delay: 15 })));
          costs.push(
            await step(page, cdp, module, box, async () => {
              await page.keyboard.press("Shift+Enter");
              await page.keyboard.type("and one more line", { delay: 15 });
            }),
          );
          costs.push(await step(page, cdp, module, box, () => page.keyboard.insertText(` ${LONG}`)));
          costs.push(await step(page, cdp, module, box, clear));
          const { frames, marks, shift } = await stopFrames(page);
          const report: Report = {
            engine: name,
            lagging,
            ...analyse(frames, marks, line),
            costs,
            layoutShift: name === "chromium" ? Math.round(shift * 10_000) / 10_000 : null,
          };
          console.log(`COMPOSER_GROWTH_FIELD ${JSON.stringify(report)}`);
          expect(report.runs.length, "growth motions").toBe(5);
          // No blank frame and none moving backwards, loaded or not. A still frame inside a motion at rest
          // is the box lagging its text; under the busy thread a long task can hold a frame's clock
          // (the base did too), so there it is reported, not asserted.
          expect({ blank: report.blank, back: report.back }).toEqual({ blank: 0, back: 0 });
          if (!lagging) expect(report.stalls, "still frames inside a motion").toBe(0);
          // The card's bottom never moves: the stack grows upward.
          expect(report.anchorShift, "card bottom shift (px)").toBeLessThanOrEqual(0.5);
          if (!lagging) {
            // Eased over frames: a typed line moves no more than a line in one frame (a clear or a long
            // insertion moves several lines in the same time).
            for (const run of report.runs.slice(1, 3))
              expect(run.maxStep, `largest one-frame step of ${run.from} -> ${run.to} (px)`).toBeLessThanOrEqual(line);
            for (const run of report.runs) expect(run.ms, `motion ${run.from} -> ${run.to}`).toBeLessThanOrEqual(320);
          }
        } finally {
          await page.close();
        }
      });

      test(`${name}${lagging ? ", lagging" : ""}: the goal row opens and folds with no stalled, blank or jumping frame`, async () => {
        const page = await open(name, GOAL, "with-hat", ".acpmux-dock > .acpmux-goal[data-look]");
        const cdp = name === "chromium" ? await page.context().newCDPSession(page) : undefined;
        await cdp?.send("Performance.enable");
        try {
          const line = await page.evaluate(() =>
            Number.parseFloat(getComputedStyle(document.querySelector(".acpmux-goal-clip")!).lineHeight),
          );
          if (lagging) await lag(page, 40, 70);
          await startFrames(page, "goal");
          const toggle = page.locator(".acpmux-goal-toggle");
          const point = (await toggle.boundingBox())!;
          const costs: Cost[] = [];
          for (let click = 0; click < 6; click++)
            costs.push(
              await step(page, cdp, "TaskGoalStrip.tsx", ".acpmux-goal", () =>
                page.mouse.click(point.x + 160, point.y + 14),
              ),
            );
          const { frames, marks, shift } = await stopFrames(page);
          const report: Report = {
            engine: name,
            lagging,
            ...analyse(frames, marks, line),
            costs,
            layoutShift: name === "chromium" ? Math.round(shift * 10_000) / 10_000 : null,
          };
          console.log(`COMPOSER_GROWTH_GOAL ${JSON.stringify(report)}`);
          expect(report.runs.length, "fold motions").toBe(6);
          expect({ blank: report.blank, back: report.back }).toEqual({ blank: 0, back: 0 });
          if (!lagging) expect(report.stalls, "still frames inside a fold").toBe(0);
          // The composer stays put and the objective's first line stays on its box's top.
          expect(report.anchorShift, "composer bottom shift (px)").toBeLessThanOrEqual(0.5);
          expect(report.lineShift, "first line against its box (px)").toBeLessThanOrEqual(0.5);
          if (!lagging)
            for (const run of report.runs) expect(run.ms, `fold ${run.from} -> ${run.to}`).toBeLessThanOrEqual(320);
        } finally {
          await page.close();
        }
      });
    }
});
