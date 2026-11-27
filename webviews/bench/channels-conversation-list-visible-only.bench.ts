// l10n-allow-file: benchmark output, not shipped UI.
// The Channels conversation list at N conversations on Chromium, a production build (React Compiler,
// minified) of test/browser/channels-conversation-list-visible-only.html: the real list, held as the
// page holds it. The visible-only rule's numbers, per N:
//   rows, nodes     mounted rows and DOM nodes under the list once it settles;
//   select          row renders when a click selects a row;
//   change          row renders when one conversation (in view) gets a new message;
//   tick            row renders when the list's parent renders again with nothing changed (a clock tick);
//   scroll          row renders per one-row (44 px) scroll step, and main-thread ms per frame (p95) while
//                   the list scrolls 44 px a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window (and the list, a third of it) narrows
//                   4 px a frame for FRAMES frames.
//   bun bench/channels-conversation-list-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/channels-conversation-list-visible-only.harness.tsx declares the same).
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
const ROW_PX = 44;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where `drive` moves the
/// page) to the task after it painted.
function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const list = document.querySelector<HTMLElement>(".lg-list-rows")!;
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
            if (kind === "scroll") list.scrollTop += step;
            else root.style.width = `${1200 - frame * step}px`;
          },
        );
      }),
    { kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/channels-conversation-list-visible-only.html");
try {
  for (const n of NS) {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true && !!document.querySelector(".lg-list-group > li"));
    await page.evaluate(() => window.cmuxPaintFrame());
    const mounted = await page.evaluate(() => {
      const list = document.querySelector(".lg-list-rows")!;
      return { rows: list.querySelectorAll(".lg-list-group > li").length, nodes: list.querySelectorAll("*").length };
    });

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.locator("[data-list-row]").nth(2).click();
    await page.evaluate(() => window.cmuxPaintFrame());
    const select = await page.evaluate(() => window.benchRowRenders.since());

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchChangeOne(4));
    await page.evaluate(() => window.cmuxPaintFrame());
    const change = await page.evaluate(() => window.benchRowRenders.since());

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchTick());
    await page.evaluate(() => window.cmuxPaintFrame());
    const tick = await page.evaluate(() => window.benchRowRenders.since());

    const steps: number[] = [];
    for (let index = 0; index < 10; index++) {
      steps.push(
        await page.evaluate(async (step) => {
          window.benchRowRenders.mark();
          await window.cmuxPaintFrame(() => {
            document.querySelector<HTMLElement>(".lg-list-rows")!.scrollTop += step;
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
      `channels-conversation-list-visible-only n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
        `nodes=${mounted.nodes} select=${select} change=${change} tick=${tick} scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
        `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
    );
  }
} finally {
  await browser.close();
  await served.close();
}
