// l10n-allow-file: benchmark output, not shipped UI.
// The Plain English diff view at N hunks on Chromium, a production build (React Compiler, minified)
// of test/browser/plain-english-visible-only.html: the real view over N / 10 files of 10 hunks and a
// stand-in host whose sentences the bench answers. The visible-only rule's numbers, per N:
//   rows, nodes     mounted hunk rows and DOM nodes under the view once it settles;
//   sentence        other rows drawn when one sentence arrives (its own row redraws from the store);
//   scroll          row renders per one-row (54 px) scroll step, and main-thread ms per frame (p95) while
//                   the view scrolls 54 px a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 4 px a frame for FRAMES frames.
//   bun bench/plain-english-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/plain-english-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchAnswerOne(): boolean;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const FRAMES = 120;
const ROW_PX = 54;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where `drive` moves the
/// page) to the task after it painted.
function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const view = document.querySelector<HTMLElement>(".plain-english")!;
        const root = document.getElementById("root")!;
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
            if (kind === "scroll") view.scrollTop += step;
            else root.style.width = `${1200 - frame * step}px`;
          },
        );
      }),
    { kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/plain-english-visible-only.html");
try {
  for (const n of NS) {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true && !!document.querySelector(".plain-english-hunk"));
    await page.evaluate(() => window.cmuxPaintFrame());
    // The rows near the window have asked for their sentences.
    await page.waitForFunction(() => document.querySelector('.plain-english-row[aria-busy="true"]') !== null);
    await page.evaluate(() => window.cmuxPaintFrame());
    const mounted = await page.evaluate(() => {
      const view = document.querySelector(".plain-english")!;
      return { rows: view.querySelectorAll(".plain-english-hunk").length, nodes: view.querySelectorAll("*").length };
    });

    await page.evaluate(() => window.benchRowRenders.mark());
    const answered = await page.evaluate(() => window.benchAnswerOne());
    await page.waitForFunction(() => document.querySelector('.plain-english-row[data-state="ready"]') !== null);
    await page.evaluate(() => window.cmuxPaintFrame());
    const sentence = answered ? await page.evaluate(() => window.benchRowRenders.since()) : -1;

    const steps: number[] = [];
    for (let index = 0; index < 10; index++) {
      steps.push(
        await page.evaluate(async (step) => {
          window.benchRowRenders.mark();
          await window.cmuxPaintFrame(() => {
            document.querySelector<HTMLElement>(".plain-english")!.scrollTop += step;
          });
          await window.cmuxPaintFrame();
          return window.benchRowRenders.since();
        }, ROW_PX),
      );
    }
    const scrollFrames = await framePass(page, "scroll", FRAMES, ROW_PX);
    const resizeFrames = await framePass(page, "resize", FRAMES, 4);
    await context.close();
    console.log(
      `plain-english-visible-only n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
        `nodes=${mounted.nodes} sentence=${sentence} scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
        `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
    );
  }
} finally {
  await browser.close();
  await served.close();
}
