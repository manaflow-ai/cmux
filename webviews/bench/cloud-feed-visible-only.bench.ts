// l10n-allow-file: benchmark output, not shipped UI.
// The Cloud page's Files list and the Feed Inbox detail's diff at N rows on Chromium, a production
// build (React Compiler, minified) of the real pages over their mock providers:
// test/browser/cloud-visible-only.html (a folder of N entries) and test/browser/feed-visible-only.html
// (an edit request whose diff has N lines). The visible-only rule's numbers, per surface and N:
//   rows, nodes     mounted rows (file rows, diff lines) and DOM nodes under the list once it settles;
//   change          row renders when the page reads its data again with one entry changed (Cloud: one
//                   file grew; Feed: the item's title changed, its diff the same);
//   scroll          row renders per one-row scroll step, and main-thread ms per frame (p95) while the
//                   page's scroller moves one row a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 4 px a frame for FRAMES frames.
//   bun bench/cloud-feed-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harnesses install (test/browser/{cloud,feed}-visible-only.harness.tsx declare the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const FRAMES = 120;

const SURFACES = [
  {
    name: "cloud-files",
    page: "/test/browser/cloud-visible-only.html",
    list: ".cloud-files",
    row: ".cloud-file",
    scroller: ".cloud-body",
    step: 29,
  },
  {
    name: "feed-diff",
    page: "/test/browser/feed-visible-only.html",
    list: ".feed-detail .feed-diff-lines",
    row: ".feed-diff-line",
    scroller: ".feed-detail-scroll",
    step: 14,
  },
] as const;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where the page moves) to
/// the task after it painted.
function framePass(page: Page, scroller: string, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ scroller, kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const element = document.querySelector<HTMLElement>(scroller)!;
        const root = document.getElementById("bench-root")!;
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
            if (kind === "scroll") element.scrollTop += step;
            else root.style.width = `${1200 - frame * step}px`;
          },
        );
      }),
    { scroller, kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
try {
  for (const surface of SURFACES) {
    const served = await serveBenchPage(surface.page);
    try {
      for (const n of NS) {
        const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
        const page = await context.newPage();
        await installPaintedFrames(page);
        await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
        await requireProductionReact(page, { dev: served.dev });
        await page.waitForFunction((row) => window.benchReady === true && !!document.querySelector(row), surface.row, {
          timeout: 120_000,
        });
        await page.evaluate(() => window.cmuxPaintFrame());
        // The list starts below the fold on the Cloud page: bring its top into view first.
        await page.evaluate(({ list, scroller }) => {
          const element = document.querySelector<HTMLElement>(scroller)!;
          const top = document.querySelector<HTMLElement>(list)!.getBoundingClientRect().top;
          element.scrollTop += top - element.getBoundingClientRect().top;
        }, surface);
        await page.evaluate(() => window.cmuxPaintFrame());
        await page.evaluate(() => window.cmuxPaintFrame());
        const mounted = await page.evaluate(({ list, row }) => {
          const element = document.querySelector(list)!;
          return { rows: element.querySelectorAll(row).length, nodes: element.querySelectorAll("*").length };
        }, surface);

        await page.evaluate(() => window.benchRowRenders.mark());
        await page.evaluate(() => window.benchChangeOne());
        await page.evaluate(() => window.cmuxPaintFrame());
        await page.evaluate(() => window.cmuxPaintFrame());
        const change = await page.evaluate(() => window.benchRowRenders.since());

        const steps: number[] = [];
        for (let index = 0; index < 10; index++) {
          steps.push(
            await page.evaluate(async ({ scroller, step }) => {
              window.benchRowRenders.mark();
              await window.cmuxPaintFrame(() => {
                document.querySelector<HTMLElement>(scroller)!.scrollTop += step;
              });
              await window.cmuxPaintFrame();
              return window.benchRowRenders.since();
            }, surface),
          );
        }
        const scrollFrames = await framePass(page, surface.scroller, "scroll", FRAMES, surface.step);
        const resizeFrames = await framePass(page, surface.scroller, "resize", FRAMES, 4);
        await context.close();
        console.log(
          `${surface.name} n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
            `nodes=${mounted.nodes} change=${change} scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
            `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
        );
      }
    } finally {
      await served.close();
    }
  }
} finally {
  await browser.close();
}
