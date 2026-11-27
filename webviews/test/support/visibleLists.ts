// The visible-only list measure: a list's case (test/browser/visible-lists/*.case.tsx) in a
// production build of the harness (React's production build, the React Compiler on, `minify:
// false` so component names survive for the render counts), in headless Chromium.
//
// For each case at N items it reads
// - mounted rows and the list's DOM nodes;
// - row renders per step (typing one key, one scroll step of one row, a hover onto the next row,
//   one item changed, one resize step of 1 px), from the commit hook (visibleListsHook.ts);
// - main-thread time per step: the renderer's TaskDuration (CDP Performance.getMetrics) across the
//   step and the two frames after it. Waiting for the display's next frame is idle, not counted,
//   so this is the work a key, scroll or resize costs. The timing passes run with the commit hook
//   off, so its fiber walk is not timed.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type CDPSession, type Page } from "playwright";

export type VisibleStep = "type" | "scroll" | "hover" | "changeOne" | "resize";

export interface StepNumbers {
  /** Row renders per step: the largest seen, and the mean. */
  rowRendersMax: number;
  rowRendersMean: number;
  /** Main-thread milliseconds per step: p95 and median. */
  taskMsP95: number;
  taskMsP50: number;
  steps: number;
}

/** Row renders from mounting a case through two frames after: in all, and in the one commit with
 * the most (a list that mounted every row for one commit before windowing them shows it here). */
export interface MountCounts {
  renders: number;
  mounts: number;
  peakRenders: number;
  peakMounts: number;
}

export interface VisibleListOpen {
  page: Page;
  mountCounts: MountCounts;
  /** Mounted rows and the DOM nodes under the list. */
  counts(): Promise<{ rows: number; domNodes: number }>;
  measure(step: VisibleStep, steps?: number): Promise<StepNumbers>;
  close(): Promise<void>;
}

export interface VisibleListsServer {
  open(caseName: string, n: number, viewport?: { width: number; height: number }): Promise<VisibleListOpen>;
  stop(): Promise<void>;
}

const webviews = path.resolve(import.meta.dir, "../..");

export async function startVisibleLists(): Promise<VisibleListsServer> {
  const { build } = await import("vite");
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "visible-lists-"));
  const input = path.join(webviews, "test/browser/visible-lists.html");
  // `bun test` runs with NODE_ENV=test, which would build dev JSX against production React.
  const environment = process.env.NODE_ENV;
  process.env.NODE_ENV = "production";
  await build({
    configFile: path.join(webviews, "vite.config.ts"),
    mode: "production",
    logLevel: "error",
    build: {
      outDir: out,
      emptyOutDir: true,
      minify: false,
      rollupOptions: { input },
      rolldownOptions: { input },
    } as Record<string, unknown>,
  });
  if (environment === undefined) delete process.env.NODE_ENV;
  else process.env.NODE_ENV = environment;
  const html = path.relative(webviews, input);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = decodeURIComponent(new URL(request.url).pathname);
      const file = Bun.file(path.join(out, pathname === "/" ? html : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  const browser: Browser = await chromium.launch({ headless: true });
  return {
    async open(caseName, n, viewport = { width: 900, height: 700 }) {
      const page = await browser.newPage({ viewport });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(String(error)));
      // The page's chunks are relative to it (`./chunks/...`): it is served at the root.
      await page.goto(`http://127.0.0.1:${statics.port}/?case=${caseName}&n=${n}`);
      await page.waitForFunction(() => "__visibleList" in window);
      const { rowSelector, rowComponents, mountCounts } = await page.evaluate(
        () =>
          (
            window as unknown as {
              __visibleList: {
                ready: Promise<{ rowSelector: string; rowComponents: string[]; mountCounts: MountCounts }>;
              };
            }
          ).__visibleList.ready,
      );
      if (errors.length) throw new Error(errors.join("\n"));
      await frames(page);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Performance.enable");
      return {
        page,
        mountCounts,
        counts: () =>
          page.evaluate((selector) => {
            const controls = (window as unknown as { __visibleListControls: { list(): HTMLElement } })
              .__visibleListControls;
            const list = controls.list();
            return { rows: list.querySelectorAll(selector).length, domNodes: list.querySelectorAll("*").length };
          }, rowSelector),
        measure: (step, steps = 20) => measure(page, cdp, step, steps, rowSelector, rowComponents),
        close: () => page.close(),
      };
    },
    async stop() {
      await browser.close();
      await statics.stop(true);
      fs.rmSync(out, { recursive: true, force: true });
    },
  };
}

/** Two painted frames: what a step waits for its renders and measurements to land. */
export const frames = (page: Page) =>
  page.evaluate(() => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));

async function taskSeconds(cdp: CDPSession): Promise<number> {
  const { metrics } = await cdp.send("Performance.getMetrics");
  return metrics.find((metric) => metric.name === "TaskDuration")?.value ?? 0;
}

const TYPED = "item 0123";

async function doStep(page: Page, step: VisibleStep, index: number, rowSelector: string) {
  switch (step) {
    case "type": {
      // Type the query, then take it back: every step is one key. Steps count from 1, so the first
      // step types the query's first key.
      const forward = (index - 1) % (TYPED.length * 2);
      await page.keyboard.press(forward < TYPED.length ? TYPED[forward]! : "Backspace");
      return;
    }
    case "scroll":
      await page.evaluate((selector) => {
        const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
          .__visibleListControls;
        const scroller = controls.scroller();
        const row = scroller.querySelector<HTMLElement>(selector);
        scroller.scrollTop += row?.getBoundingClientRect().height || 28;
      }, rowSelector);
      return;
    case "hover": {
      // The next row below the one under the pointer, among those in view.
      const box = await page.evaluate(
        ({ selector, index }) => {
          const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
            .__visibleListControls;
          const scroller = controls.scroller();
          const view = scroller.getBoundingClientRect();
          const rows = [...scroller.querySelectorAll<HTMLElement>(selector)]
            .map((row) => row.getBoundingClientRect())
            .filter((rect) => rect.top >= view.top && rect.bottom <= view.bottom)
            .sort((a, b) => a.top - b.top);
          const rect = rows[index % Math.max(1, rows.length)];
          return rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null;
        },
        { selector: rowSelector, index },
      );
      if (box) await page.mouse.move(box.x, box.y);
      return;
    }
    case "changeOne":
      await page.evaluate(() =>
        (window as unknown as { __visibleListControls: { changeOne?(): void } }).__visibleListControls.changeOne?.(),
      );
      return;
    case "resize":
      await page.evaluate((index) => {
        const controls = (window as unknown as { __visibleListControls: { resizeTarget?(): HTMLElement } })
          .__visibleListControls;
        const target = controls.resizeTarget?.() ?? document.getElementById("root")!;
        target.style.width = `${420 - (index % 20)}px`;
      }, index);
      return;
  }
}

async function measure(
  page: Page,
  cdp: CDPSession,
  step: VisibleStep,
  steps: number,
  rowSelector: string,
  rowComponents: readonly string[],
): Promise<StepNumbers> {
  if (step === "type")
    await page.evaluate(() =>
      (window as unknown as { __visibleListControls: { filter?(): HTMLElement } }).__visibleListControls
        .filter?.()
        .focus(),
    );
  // A step that only places the pointer first, so hover steps move from row to row.
  if (step === "hover") await doStep(page, step, 0, rowSelector);
  await frames(page);
  // Counting pass.
  const renders: number[] = [];
  for (let index = 1; index <= steps; index++) {
    await page.evaluate(() =>
      (window as unknown as { __visibleList: { renderCounts: { start(): void } } }).__visibleList.renderCounts.start(),
    );
    await doStep(page, step, index, rowSelector);
    await frames(page);
    renders.push(
      await page.evaluate((names) => {
        const counts = (
          window as unknown as {
            __visibleList: { renderCounts: { stop(): void; read(names: readonly string[]): { renders: number } } };
          }
        ).__visibleList.renderCounts;
        counts.stop();
        return counts.read(names).renders;
      }, rowComponents),
    );
  }
  // Timing pass, the hook off.
  const times: number[] = [];
  for (let index = steps + 1; index <= steps * 2; index++) {
    const before = await taskSeconds(cdp);
    await doStep(page, step, index, rowSelector);
    await frames(page);
    times.push((await taskSeconds(cdp)) - before);
  }
  const ms = times.map((seconds) => seconds * 1000).sort((a, b) => a - b);
  const at = (quantile: number) => ms[Math.min(ms.length - 1, Math.ceil(quantile * ms.length) - 1)] ?? 0;
  return {
    rowRendersMax: Math.max(0, ...renders),
    rowRendersMean: renders.reduce((a, b) => a + b, 0) / Math.max(1, renders.length),
    taskMsP95: round(at(0.95)),
    taskMsP50: round(at(0.5)),
    steps,
  };
}

const round = (value: number) => Math.round(value * 10) / 10;
