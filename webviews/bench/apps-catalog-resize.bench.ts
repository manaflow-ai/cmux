// l10n-allow-file: benchmark output, not shipped UI.
// The App Store's Discover grid across one resize step at N listings, a production build of
// test/browser/apps-catalog-visible-only.html (the real page over a stand-in owner), in Chromium or
// WebKit. Per run (a fresh browser): the page at 1200x800, #root at the step's first width, the catalog
// scrolled 30,000 px, then STEPS single-frame width steps alternating between the step's two widths,
// 3 idle frames between steps:
//   columns   1000 <-> 760 px: the grid's 3 <-> 2 columns, so every listing moves to another row;
//   same      1000 <-> 960 px: 3 columns at both, so the rows stay and the cards resize.
// A step's frame is main-thread ms from the frame's callback that sets the width to the task after
// that frame painted. Each run prints the steps' frame p95 (and max, median), and for the column
// change the catalog cards per step that stayed the same element (`kept`) or mounted (`mounted`) and
// any listing mounted before and after whose card is another element (`replaced`, 0 when cards are
// kept by listing). The last lines are the median and range of the runs' p95.
//   bun bench/apps-catalog-resize.bench.ts [chromium|webkit] [runs=5] [n=10000]
/// <reference types="bun" />
import type { Browser, Page } from "playwright";
import { chromium, webkit } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

// What the harness installs (test/browser/apps-catalog-visible-only.harness.tsx declares the same).
declare global {
  interface Window {
    benchReady: boolean;
  }
}

const [engine = "chromium", runsArg = "5", nArg = "10000"] = benchPositionals();
if (engine !== "chromium" && engine !== "webkit") throw new Error(`usage: [chromium|webkit] [runs] [n], not ${engine}`);
const RUNS = Number(runsArg);
const N = Number(nArg);
const STEPS = 20;
const SCROLL_TO = 30_000;
const PAIRS = { columns: [1000, 760], same: [1000, 960] } as const;
const CARDS = ".apps-catalog-space .apps-card";

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/** STEPS steps alternating between `a` and `b`: each step frame's ms, and per step the cards kept
 *  (same element), mounted, and replaced (a listing mounted before and after on another element). */
function stepPass(page: Page, a: number, b: number) {
  return page.evaluate(
    ({ a, b, steps, cards }) =>
      new Promise<{ frames: number[]; kept: number[]; mounted: number[]; replaced: number[] }>((resolve) => {
        const root = document.getElementById("root")!;
        const out = { frames: [] as number[], kept: [] as number[], mounted: [] as number[], replaced: [] as number[] };
        let before = new Map<string, Element>();
        let frame = 0;
        let started = 0;
        let stepped = false;
        let step = 0;
        window.cmuxAfterPaint(
          () => {
            if (stepped) {
              out.frames.push(performance.now() - started);
              // Read after the frame's time is taken, so the read is not in it.
              const after = [...document.querySelectorAll<HTMLElement>(cards)];
              const kept = after.filter((card) => before.has(card.dataset.app!));
              out.kept.push(kept.filter((card) => before.get(card.dataset.app!) === card).length);
              out.replaced.push(kept.filter((card) => before.get(card.dataset.app!) !== card).length);
              out.mounted.push(after.filter((card) => before.get(card.dataset.app!) !== card).length);
            }
            stepped = false;
            if (step < steps || frame % 4 !== 3) return true;
            resolve(out);
            return false;
          },
          () => {
            frame++;
            // A step every 4th frame: 3 idle frames between steps let the previous one settle.
            if (frame % 4 !== 0 || step >= steps) return;
            before = new Map(
              [...document.querySelectorAll<HTMLElement>(cards)].map((card) => [card.dataset.app!, card]),
            );
            step++;
            stepped = true;
            started = performance.now();
            root.style.width = `${step % 2 === 1 ? b : a}px`;
          },
        );
      }),
    { a, b, steps: STEPS, cards: CARDS },
  );
}

async function settle(page: Page, frames = 6) {
  for (let i = 0; i < frames; i++) await page.evaluate(() => window.cmuxPaintFrame());
}

const launcher = engine === "webkit" ? webkit : chromium;
const served = await serveBenchPage("/test/browser/apps-catalog-visible-only.html");
const p95s: Record<string, number[]> = { columns: [], same: [] };
let build = "production";
try {
  for (let run = 1; run <= RUNS; run++) {
    const browser: Browser = await launcher.launch({ headless: true });
    try {
      const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}&layout=grid` });
      await requireProductionReact(page, { dev: served.dev });
      build = served.dev ? "dev" : "production";
      await page.waitForFunction((cards) => window.benchReady === true && !!document.querySelector(cards), CARDS, {
        timeout: 180_000,
      });
      const out: string[] = [];
      for (const [name, [a, b]] of Object.entries(PAIRS)) {
        await page.evaluate((a) => (document.getElementById("root")!.style.width = `${a}px`), a);
        await settle(page);
        await page.evaluate((y) => (document.querySelector<HTMLElement>(".apps-scroll")!.scrollTop = y), SCROLL_TO);
        await settle(page);
        const { frames, kept, mounted, replaced } = await stepPass(page, a, b);
        p95s[name]!.push(pct(frames, 0.95));
        out.push(
          `${name}=${a}<->${b} p95=${pct(frames, 0.95).toFixed(1)}ms max=${Math.max(...frames).toFixed(1)}ms ` +
            `med=${pct(frames, 0.5).toFixed(1)}ms kept=${pct(kept, 0.5)} mounted=${pct(mounted, 0.5)}/${Math.max(...mounted)} ` +
            `replaced=${Math.max(...replaced)}`,
        );
      }
      await context.close();
      console.log(`apps-catalog-resize engine=${engine} run=${run} n=${N} build=${build} ${out.join(" | ")}`);
    } finally {
      await browser.close();
    }
  }
} finally {
  await served.close();
}
for (const [name, values] of Object.entries(p95s))
  console.log(
    `apps-catalog-resize summary engine=${engine} n=${N} build=${build} ${name} runs=${values.length} ` +
      `p95 median=${pct(values, 0.5).toFixed(1)}ms range=${Math.min(...values).toFixed(1)}-${Math.max(...values).toFixed(1)}ms`,
  );
