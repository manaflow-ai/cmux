// l10n-allow-file: benchmark output, not shipped UI.
// The Task Manager page (pages/task-manager) at N processes on Chromium, a production build of
// test/browser/task-manager-rows.html. Run it on two builds (the label names the build) to compare.
// Per round, on a fresh page:
//   mount    ms from render() to the first painted frame;
//   sample   ms from a new sample (every row's CPU and memory change) to its painted frame, p50 of SAMPLES;
//   sort     ms from a header's sort (CPU, then back to the app's order) to its painted frame, p50;
//   scroll   main-thread ms per frame (p95) while the table scrolls 60 px a frame for FRAMES frames.
// It prints each round, then the p50 and spread (min..max) over the rounds.
//   bun bench/task-manager-rows.bench.ts [rounds=5] [n=2000] [label=build]
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";
import type { TaskManagerSnapshot } from "../src/pages/task-manager/types";
import type { TaskManagerStore } from "../src/pages/task-manager/store";

declare global {
  interface Window {
    benchReady: boolean;
    benchMountMs: number;
    benchStore: TaskManagerStore;
    benchSample: (revision: number) => TaskManagerSnapshot;
  }
}

const [roundsArg, nArg, labelArg] = benchPositionals();
const ROUNDS = Number(roundsArg ?? 5);
const N = Number(nArg ?? 2000);
const LABEL = labelArg ?? "build";
const FRAMES = 120;
const SAMPLES = 8;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/** ms from `act` (one store change) to the frame that painted it. */
function painted(page: Page, act: "sample" | "sort", step: number) {
  return page.evaluate(
    ({ act, step }) =>
      new Promise<number>((resolve) => {
        const sample = act === "sample" ? window.benchSample(step + 2) : null;
        const started = performance.now();
        if (sample) window.benchStore.replace(sample);
        else window.benchStore.sortBy("cpu");
        window.cmuxAfterPaint(() => {
          resolve(performance.now() - started);
          return false;
        });
      }),
    { act, step },
  );
}

function scrollPass(page: Page, frames: number, step: number) {
  return page.evaluate(
    ({ frames, step }) =>
      new Promise<number[]>((resolve) => {
        const list = document.querySelector<HTMLElement>(".tm-table-scroll")!;
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
            list.scrollTop += step;
          },
        );
      }),
    { frames, step },
  );
}

type Result = { mount: number; sample: number; sort: number; scroll: number; drawn: number };
const results: Result[] = [];
const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/task-manager-rows.html");
try {
  for (let round = 0; round < ROUNDS; round++) {
    const context = await browser.newContext({ viewport: { width: 900, height: 700 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true);
    const mount = await page.evaluate(() => window.benchMountMs);
    const drawn = await page.evaluate(() => document.querySelectorAll(".tm-row").length);
    await page.evaluate(() => window.cmuxPaintFrame());
    const samples: number[] = [];
    for (let step = 0; step < SAMPLES; step++) samples.push(await painted(page, "sample", step));
    const sorts: number[] = [];
    for (let step = 0; step < SAMPLES; step++) sorts.push(await painted(page, "sort", step));
    await page.evaluate(() => window.cmuxPaintFrame());
    const scroll = pct(await scrollPass(page, FRAMES, 60), 0.95);
    await context.close();
    const row = { mount, sample: pct(samples, 0.5), sort: pct(sorts, 0.5), scroll, drawn };
    results.push(row);
    console.log(
      `task-manager-rows round=${round} label=${LABEL} n=${N} build=${served.dev ? "dev" : "production"} ` +
        `drawn=${drawn} mount=${mount.toFixed(1)}ms sample=${row.sample.toFixed(1)}ms sort=${row.sort.toFixed(1)}ms ` +
        `scrollP95=${scroll.toFixed(1)}ms`,
    );
  }
  const line = (["mount", "sample", "sort", "scroll"] as const)
    .map((key) => {
      const values = results.map((row) => row[key]);
      return `${key} p50=${pct(values, 0.5).toFixed(1)}ms (${Math.min(...values).toFixed(1)}..${Math.max(...values).toFixed(1)})`;
    })
    .join(" ");
  console.log(`task-manager-rows summary label=${LABEL} n=${N} rounds=${ROUNDS} drawn=${results[0]?.drawn} ${line}`);
} finally {
  await browser.close();
  await served.close();
}
