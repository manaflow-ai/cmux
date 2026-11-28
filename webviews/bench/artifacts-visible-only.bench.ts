// l10n-allow-file: benchmark output, not shipped UI.
// The Artifacts page's history and a revision's change at N lines on Chromium, a production build
// (React Compiler, minified) of test/browser/artifacts-visible-only.html: the real page over a
// stand-in host whose one file has N lines and HISTORY_LIMIT revisions, the newest adding every line.
// The visible-only rule's numbers, per N:
//   lines, nodes    mounted diff lines and DOM nodes under the change once it settles;
//   change          diff line and history row renders when a refresh renames one older revision;
//   choose          history row renders when a click chooses the third revision;
//   scroll          line renders per one-line (14 px) scroll step, and main-thread ms per frame (p95)
//                   while the history pane scrolls 14 px a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 4 px a frame for FRAMES frames.
//   bun bench/artifacts-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/artifacts-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchCommitRenders: { mark(): void; since(): number };
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const FRAMES = 120;
const LINE_PX = 14;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where `drive` moves the
/// page) to the task after it painted.
function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const scroller = document.querySelector<HTMLElement>(".artifacts-history")!;
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

/// Line and history row renders while `act` runs in the page, read after a painted frame.
async function rendersOf(page: Page, act: () => Promise<void>) {
  await page.evaluate(() => {
    window.benchRowRenders.mark();
    window.benchCommitRenders.mark();
  });
  await act();
  await page.evaluate(() => window.cmuxPaintFrame());
  await page.evaluate(() => window.cmuxPaintFrame());
  return page.evaluate(() => ({ lines: window.benchRowRenders.since(), commits: window.benchCommitRenders.since() }));
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/artifacts-visible-only.html");
try {
  for (const n of NS) {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true && !!document.querySelector(".artifacts-line"), {
      timeout: 120_000,
    });
    await page.evaluate(() => window.cmuxPaintFrame());
    const mounted = await page.evaluate(() => {
      const diff = document.querySelector(".artifacts-diff")!;
      return { lines: diff.querySelectorAll(".artifacts-line").length, nodes: diff.querySelectorAll("*").length };
    });

    const change = await rendersOf(page, () => page.evaluate(() => window.benchChangeOne()));

    const steps: number[] = [];
    for (let index = 0; index < 10; index++) {
      steps.push(
        await page.evaluate(async (step) => {
          window.benchRowRenders.mark();
          await window.cmuxPaintFrame(() => {
            document.querySelector<HTMLElement>(".artifacts-history")!.scrollTop += step;
          });
          await window.cmuxPaintFrame();
          return window.benchRowRenders.since();
        }, LINE_PX),
      );
    }
    const scrollFrames = await framePass(page, "scroll", FRAMES, LINE_PX);
    const resizeFrames = await framePass(page, "resize", FRAMES, 4);
    await page.evaluate(() => {
      document.querySelector<HTMLElement>(".artifacts-history")!.scrollTop = 0;
      document.getElementById("root")!.style.width = "";
    });
    const choose = await rendersOf(page, () => page.locator(".artifacts-commit-button").nth(2).click());
    await context.close();
    console.log(
      `artifacts-visible-only n=${n} build=${served.dev ? "dev" : "production"} lines=${mounted.lines} ` +
        `nodes=${mounted.nodes} change=${change.lines}+${change.commits} choose=${choose.commits} ` +
        `scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
        `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
    );
  }
} finally {
  await browser.close();
  await served.close();
}
