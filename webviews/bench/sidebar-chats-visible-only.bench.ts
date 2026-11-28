// l10n-allow-file: benchmark output, not shipped UI.
// The sidebar chats page at N Earlier rows on Chromium, a production build (React Compiler, minified) of
// test/browser/sidebar-chats-visible-only.html: the real page over a stand-in host that sends all N and,
// as the native host does, a slice of the page in sight one frame after each scroll. Per N:
//   rows, nodes     mounted rows and DOM nodes under the root once it settles;
//   change          row renders when the host's next block retitles one chat;
//   tick            row renders on the host's age tick when no age label moved;
//   scroll          row renders per one-row (30 px) scroll step, and main-thread ms per frame (p95) while
//                   the page scrolls 30 px a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 2 px a frame for FRAMES frames.
//   bun bench/sidebar-chats-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/sidebar-chats-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchChangeOne(index?: number): void | Promise<void>;
    benchTick(): void;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const FRAMES = 120;
const ROW_PX = 30;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where `drive` moves the
/// page) to the task after it painted.
function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
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
            if (kind === "scroll") document.scrollingElement!.scrollTop += step;
            else root.style.width = `${260 - frame * step}px`;
          },
        );
      }),
    { kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/sidebar-chats-visible-only.html");
const paint = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());
try {
  for (const n of NS) {
    // The sidebar's width; the window is the part of the sidebar list the block shows.
    const context = await browser.newContext({ viewport: { width: 260, height: 800 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true);
    // Into the middle of the list, then a frame for the host's slice.
    await page.evaluate(() => (document.scrollingElement!.scrollTop = 6_000));
    for (let frame = 0; frame < 3; frame++) await paint(page);
    const mounted = await page.evaluate(() => ({
      rows: document.querySelectorAll(".sc-row[data-chat]").length,
      nodes: document.getElementById("root")!.querySelectorAll("*").length,
    }));

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchChangeOne(205));
    for (let frame = 0; frame < 2; frame++) await paint(page);
    const change = await page.evaluate(() => window.benchRowRenders.since());

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchTick());
    for (let frame = 0; frame < 2; frame++) await paint(page);
    const tick = await page.evaluate(() => window.benchRowRenders.since());

    const steps: number[] = [];
    for (let index = 0; index < 10; index++) {
      steps.push(
        await page.evaluate(async (step) => {
          window.benchRowRenders.mark();
          await window.cmuxPaintFrame(() => {
            document.scrollingElement!.scrollTop += step;
          });
          // The host's slice lands the frame after the scroll.
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
          return window.benchRowRenders.since();
        }, ROW_PX),
      );
    }
    const scrollFrames = await framePass(page, "scroll", FRAMES, ROW_PX);
    const resizeFrames = await framePass(page, "resize", FRAMES, 2);
    await context.close();
    console.log(
      `sidebar-chats-visible-only n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
        `nodes=${mounted.nodes} change=${change} tick=${tick} scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
        `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
    );
  }
} finally {
  await browser.close();
  await served.close();
}
