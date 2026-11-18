// l10n-allow-file: benchmark output, not shipped UI.
// An app scene's LazyVStack of N Rows in a scroller the page owns (New Tab's `.nt-app-page`), on Chromium,
// a production build of test/browser/scene-lazy-stack-visible-only.html. A scene holds at most 4,096 nodes,
// so N stops at 4,000. Per N:
//   rows, nodes     mounted rows and DOM nodes under the root once it settles, scrolled into the middle;
//   change          row renders when the host's next op retitles one row;
//   scroll          row renders per one-row scroll step (median/max), and main-thread ms per frame (p95)
//                   while the page scrolls one row a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 2 px a frame for FRAMES frames.
//   bun bench/scene-lazy-stack-visible-only.bench.ts [n...]   (default 1000 4000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchChangeOne(index: number): void;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 4_000];
const FRAMES = 120;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const root = document.getElementById("root")!;
        const scroller = document.querySelector<HTMLElement>(".nt-app-page")!;
        const work: number[] = [];
        let started = 0;
        let frame = 0;
        window.cmuxAfterPaint(
          () => {
            if (frame > 1) work.push(performance.now() - started);
            if (frame <= frames) return true;
            resolve(work);
            return false;
          },
          () => {
            frame++;
            started = performance.now();
            if (kind === "scroll") scroller.scrollTop += step;
            else root.style.width = `${900 - frame * step}px`;
          },
        );
      }),
    { kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/scene-lazy-stack-visible-only.html");
const paint = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());
try {
  for (const n of NS) {
    const context = await browser.newContext({ viewport: { width: 900, height: 800 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true);
    const stride = await page.evaluate(() => {
      const rows = document.querySelectorAll<HTMLElement>("[data-app-type=Row]");
      return rows[1]!.getBoundingClientRect().top - rows[0]!.getBoundingClientRect().top;
    });
    await page.evaluate((top) => (document.querySelector<HTMLElement>(".nt-app-page")!.scrollTop = top), 300 * stride);
    for (let frame = 0; frame < 3; frame++) await paint(page);
    const mounted = await page.evaluate(() => ({
      rows: document.querySelectorAll("[data-app-type=Row]").length,
      nodes: document.getElementById("root")!.querySelectorAll("*").length,
    }));

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchChangeOne(310));
    for (let frame = 0; frame < 2; frame++) await paint(page);
    const change = await page.evaluate(() => window.benchRowRenders.since());

    const steps: number[] = [];
    for (let index = 0; index < 10; index++) {
      steps.push(
        await page.evaluate(async (step) => {
          window.benchRowRenders.mark();
          await window.cmuxPaintFrame(() => {
            document.querySelector<HTMLElement>(".nt-app-page")!.scrollTop += step;
          });
          await window.cmuxPaintFrame();
          return window.benchRowRenders.since();
        }, stride),
      );
    }
    const scrollFrames = await framePass(page, "scroll", FRAMES, stride);
    const resizeFrames = await framePass(page, "resize", FRAMES, 2);
    await context.close();
    console.log(
      `scene-lazy-stack-visible-only n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
        `nodes=${mounted.nodes} change=${change} scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
        `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
    );
  }
} finally {
  await browser.close();
  await served.close();
}
