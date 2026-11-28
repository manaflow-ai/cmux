// l10n-allow-file: benchmark output, not shipped UI.
// Settings > Shared Links, Keys and Customization Library at N rows on Chromium, a production build (React
// Compiler, minified) of test/browser/settings-cards-visible-only.html: the real page over the
// in-memory mock host, which answers the card's list with all N. The visible-only rule's numbers,
// per card and N:
//   rows, nodes     mounted rows and DOM nodes under the card once it settles;
//   change          row renders when a read changes one row (in view);
//   tick            row renders when the card draws again a minute later on its own state;
//   scroll          row renders per one-row scroll step, and main-thread ms per frame (p95) while the
//                   page scrolls one row a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 4 px a frame for FRAMES frames.
//   bun bench/settings-cards-visible-only.bench.ts [n...]   (default 1000 10000)
//   BENCH_CARDS=library,keys picks the cards (default all).
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/settings-cards-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowSelector: string;
    benchRowRenders: { mark(): void; since(): number };
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const FRAMES = 120;
const CARDS = [
  { card: "shares", name: "sharedLinks", redraw: '[data-shared-links-action="revokeAll"]' },
  { card: "keys", name: "keys", redraw: '[data-card="keys"] [data-key-action="revoke"]' },
  {
    card: "library",
    name: "customizeLibrary",
    redraw: '[data-card="customizeLibrary"] [data-library-action="remove"]',
  },
].filter(({ card }) => !process.env.BENCH_CARDS || process.env.BENCH_CARDS.split(",").includes(card));

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where the page moves) to
/// the task after it painted.
function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const scroller = document.querySelector<HTMLElement>("main.content")!;
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
            if (kind === "scroll") scroller.scrollTop += step;
            else root.style.width = `${1200 - frame * step}px`;
          },
        );
      }),
    { kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/settings-cards-visible-only.html");
try {
  for (const { card, name, redraw } of CARDS) {
    for (const n of NS) {
      const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      await gotoBenchPage(page, { ...served, url: `${served.url}#card=${card}&n=${n}` });
      await requireProductionReact(page, { dev: served.dev });
      await page.waitForFunction(() => window.benchReady === true && !!document.querySelector(window.benchRowSelector));
      // The card's rows in view, a few rows down.
      await page.evaluate((name) => {
        const scroller = document.querySelector<HTMLElement>("main.content")!;
        const rows = document.querySelector<HTMLElement>(`[data-card="${name}"] .rows`)!;
        scroller.scrollTop += rows.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
      }, name);
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.evaluate(() => window.cmuxPaintFrame());
      const mounted = await page.evaluate((name) => {
        const rows = document.querySelector(`[data-card="${name}"] .rows`)!;
        return {
          rows: rows.querySelectorAll(window.benchRowSelector).length,
          nodes: rows.querySelectorAll("*").length,
        };
      }, name);
      // The scroller's own numbers, to check every row is in the page's height either way.
      const height = await page.evaluate(() => document.querySelector<HTMLElement>("main.content")!.scrollHeight);

      await page.evaluate(() => window.benchRowRenders.mark());
      await page.evaluate(() => window.benchChangeOne(2));
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.evaluate(() => window.cmuxPaintFrame());
      const change = await page.evaluate(() => window.benchRowRenders.since());

      // A minute on the clock, then the card draws again on its own state (Shared Links: Revoke All
      // asks first; Keys: the first row's Revoke asks first, its own state; the library: Remove asks first).
      await page.evaluate(() => {
        const real = Date.now;
        const later = real() + 60_000;
        Date.now = () => later;
      });
      await page.evaluate(() => window.benchRowRenders.mark());
      await page.locator(redraw).first().click();
      await page.evaluate(() => window.cmuxPaintFrame());
      const tick = await page.evaluate(() => window.benchRowRenders.since());
      await page.keyboard.press("Escape");

      const step = await page.evaluate(
        () => document.querySelector<HTMLElement>(window.benchRowSelector)!.getBoundingClientRect().height,
      );
      const steps: number[] = [];
      for (let index = 0; index < 10; index++) {
        steps.push(
          await page.evaluate(async (step) => {
            window.benchRowRenders.mark();
            await window.cmuxPaintFrame(() => {
              document.querySelector<HTMLElement>("main.content")!.scrollTop += step;
            });
            await window.cmuxPaintFrame();
            return window.benchRowRenders.since();
          }, step),
        );
      }
      const scrollFrames = await framePass(page, "scroll", FRAMES, step);
      const resizeFrames = await framePass(page, "resize", FRAMES, 4);
      await context.close();
      console.log(
        `settings-cards-visible-only card=${name} n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
          `nodes=${mounted.nodes} height=${height} change=${change} tick=${tick} ` +
          `scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
          `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
      );
    }
  }
} finally {
  await browser.close();
  await served.close();
}
