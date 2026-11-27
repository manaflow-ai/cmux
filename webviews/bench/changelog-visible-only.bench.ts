// l10n-allow-file: benchmark output, not shipped UI.
// What's New's day list (the sheet and the journal) and the Updated card's list at N items on
// Chromium, a production build (React Compiler, minified) of test/browser/changelog-visible-only.html.
// The visible-only rule's numbers, per list and N:
//   rows, nodes     mounted rows (days, or the card's changes) and DOM nodes once it settles;
//   change          row renders when one item changes (a day's held note loads; a change's detail),
//                   then (kept=) those of rows already mounted, which leaves out rows that mounted:
//                   past the changed row itself that must be 0, or the run exits 1 once it has printed;
//   scroll          row renders per one 40 px scroll step, and main-thread ms per frame (p95) while
//                   the list scrolls 40 px a frame for FRAMES frames;
//   resize          main-thread ms per frame (p95) while the window narrows 4 px a frame for FRAMES frames.
//   bun bench/changelog-visible-only.bench.ts [n...]   (default 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/changelog-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    benchKeptRenders: { mark(): void; since(): number };
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [1_000, 10_000];
const KINDS = ["sheet", "journal", "card"] as const;
const FRAMES = 120;
const STEP_PX = 40;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// The rows of a list, its subtree and how it scrolls, as the page evaluates them.
const LISTS = {
  sheet: { rows: ".clj-section:not(.clj-span)", tree: "#root", scroller: "" },
  journal: { rows: ".clj-section:not(.clj-span)", tree: "#root", scroller: "" },
  card: { rows: ".wn-notes-row", tree: ".wn-notes", scroller: ".wn-notes" },
} as const;

/// Main-thread ms of each of `frames` frames: from the frame's callbacks (where `drive` moves the
/// page) to the task after it painted. An empty `scroller` scrolls the document.
function framePass(page: Page, scroller: string, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ scroller, kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const list = scroller ? document.querySelector<HTMLElement>(scroller)! : document.scrollingElement!;
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
    { scroller, kind, frames, step },
  );
}

/// Lists where a row whose data did not change rendered again.
const unchangedRenders: string[] = [];
const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/changelog-visible-only.html");
try {
  for (const kind of KINDS) {
    const list = LISTS[kind];
    for (const n of NS) {
      const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}&kind=${kind}` });
      await requireProductionReact(page, { dev: served.dev });
      await page.waitForFunction((rows) => window.benchReady === true && !!document.querySelector(rows), list.rows);
      for (let i = 0; i < 5; i++) await page.evaluate(() => window.cmuxPaintFrame());
      const mounted = await page.evaluate(
        ({ rows, tree }) => ({
          rows: document.querySelectorAll(rows).length,
          nodes: document.querySelector(tree)!.querySelectorAll("*").length,
        }),
        list,
      );

      await page.evaluate(() => {
        window.benchRowRenders.mark();
        window.benchKeptRenders.mark();
      });
      await page.evaluate(() => window.benchChangeOne(0));
      for (let i = 0; i < 3; i++) await page.evaluate(() => window.cmuxPaintFrame());
      const change = await page.evaluate(() => [window.benchRowRenders.since(), window.benchKeptRenders.since()]);

      const steps: number[] = [];
      for (let index = 0; index < 10; index++) {
        steps.push(
          await page.evaluate(
            async ({ scroller, step }) => {
              window.benchRowRenders.mark();
              await window.cmuxPaintFrame(() => {
                (scroller ? document.querySelector<HTMLElement>(scroller)! : document.scrollingElement!).scrollTop +=
                  step;
              });
              await window.cmuxPaintFrame();
              return window.benchRowRenders.since();
            },
            { scroller: list.scroller, step: STEP_PX },
          ),
        );
      }
      const scrollFrames = await framePass(page, list.scroller, "scroll", FRAMES, STEP_PX);
      const resizeFrames = await framePass(page, list.scroller, "resize", FRAMES, 4);
      await context.close();
      if (change[1]! > 1) unchangedRenders.push(`${kind} n=${n}: ${change[1]! - 1}`);
      console.log(
        `changelog-visible-only ${kind} n=${n} build=${served.dev ? "dev" : "production"} rows=${mounted.rows} ` +
          `nodes=${mounted.nodes} change=${change[0]} kept=${change[1]} scrollStepRenders=${pct(steps, 0.5)}/${Math.max(...steps)} ` +
          `scrollP95=${pct(scrollFrames, 0.95).toFixed(1)}ms resizeP95=${pct(resizeFrames, 0.95).toFixed(1)}ms`,
      );
    }
  }
} finally {
  await browser.close();
  await served.close();
}
if (unchangedRenders.length > 0) {
  console.error(`unchanged rows rendered again: ${unchangedRenders.join(", ")}`);
  process.exit(1);
}
