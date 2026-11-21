// l10n-allow-file: benchmark output, not shipped UI.
// The GitHub page's CI dashboard at N jobs on Chromium, a production build (React Compiler, minified)
// of test/browser/github-visible-only.html: the real page over a stand-in host whose head has N jobs.
// The visible-only rule's numbers, per N:
//   rows, nodes     mounted dashboard rows and DOM nodes under the dashboard once it settles;
//   tick            row renders on one tick of the dashboard's clock (two jobs run);
//   change          row renders when an answer changes one job (in view);
//   scroll          row renders per one-line (24 px) scroll step, and main-thread ms per frame (p95)
//                   while the page scrolls 24 px a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the page narrows 4 px a frame for FRAMES frames.
//   bun bench/github-page-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/github-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchChangeOne(index: number): Promise<void>;
    benchTick(): void;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const FRAMES = 120;
const LINE_PX = 24;

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
            if (kind === "scroll") window.scrollBy(0, step);
            else root.style.width = `${1400 - frame * step}px`;
          },
        );
      }),
    { kind, frames, step },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/github-visible-only.html");
try {
  for (const n of NS) {
    const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true && !!document.querySelector(".gh-ci-row"));
    await page.evaluate(() => window.cmuxPaintFrame());
    const mounted = await page.evaluate(() => {
      const ci = document.querySelector(".gh-ci")!;
      return { rows: ci.querySelectorAll(".gh-ci-row").length, nodes: ci.querySelectorAll("*").length };
    });

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchTick());
    await page.evaluate(() => window.cmuxPaintFrame());
    const tick = await page.evaluate(() => window.benchRowRenders.since());

    await page.evaluate(() => window.benchRowRenders.mark());
    await page.evaluate(() => window.benchChangeOne(8));
    await page.evaluate(() => window.cmuxPaintFrame());
    const change = await page.evaluate(() => window.benchRowRenders.since());

    // Scroll the dashboard's rows to the top of the viewport, then step.
    await page.evaluate(async () => {
      const top = document.querySelector(".gh-ci-row")!.getBoundingClientRect().top + window.scrollY;
      await window.cmuxPaintFrame(() => window.scrollTo(0, top));
      await window.cmuxPaintFrame();
    });
    const steps: number[] = [];
    for (let index = 0; index < 10; index++) {
      steps.push(
        await page.evaluate(async (step) => {
          // Rows mounted before the step that are still mounted after it: those must not render.
          const names = () =>
            new Set([...document.querySelectorAll(".gh-ci-row .gh-ci-line")].map((l) => l.textContent));
          const before = names();
          window.benchRowRenders.mark();
          await window.cmuxPaintFrame(() => window.scrollBy(0, step));
          await window.cmuxPaintFrame();
          const arrived = [...names()].filter((name) => !before.has(name)).length;
          return window.benchRowRenders.since() - arrived;
        }, LINE_PX),
      );
    }
    const scrollFrames = await framePass(page, "scroll", FRAMES, LINE_PX);
    const resizeFrames = await framePass(page, "resize", FRAMES, 4);
    await context.close();
    console.log(
      `github-visible-only n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
        `nodes=${mounted.nodes} tick=${tick} change=${change} keptRowRendersPerScrollStep=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
        `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
    );
  }
} finally {
  await browser.close();
  await served.close();
}
