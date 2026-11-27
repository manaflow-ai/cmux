// l10n-allow-file: benchmark output, not shipped UI.
// The terminal transcript viewer (pages/terminal-history) at N turns on Chromium, a production build of
// test/browser/terminal-history-visible-only.html, with and without the offscreen-turn rule
// (`content-visibility: auto` on `.terminal-history-turn`, styles.css). Arms `off` and `on` alternate
// round by round on one page build. Per arm and round:
//   mount    ms from render() to the first painted frame (style, layout and paint of every turn);
//   resize   main-thread ms per frame (p95) while the window narrows 4 px a frame for FRAMES frames;
//   scroll   main-thread ms per frame (p95) while the transcript scrolls 120 px a frame for FRAMES frames.
// It prints each round, then each arm's p50 and spread (min..max) over the rounds.
//   bun bench/terminal-history-offscreen.bench.ts [rounds=5] [n=2000]
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

declare global {
  interface Window {
    benchReady: boolean;
    benchMountMs: number;
  }
}

const [roundsArg, nArg] = benchPositionals();
const ROUNDS = Number(roundsArg ?? 5);
const N = Number(nArg ?? 2000);
const FRAMES = 120;
const ARMS = ["off", "on"] as const;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

function framePass(page: Page, kind: "scroll" | "resize", frames: number, step: number) {
  return page.evaluate(
    ({ kind, frames, step }) =>
      new Promise<number[]>((resolve) => {
        const list = document.querySelector<HTMLElement>(".terminal-history-scroll")!;
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

type Row = { mount: number; resize: number; scroll: number };
const results: Record<(typeof ARMS)[number], Row[]> = { off: [], on: [] };
const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/terminal-history-visible-only.html");
try {
  for (let round = 0; round < ROUNDS; round++) {
    const order = round % 2 ? [...ARMS].reverse() : ARMS;
    for (const arm of order) {
      const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}&arm=${arm}` });
      await requireProductionReact(page, { dev: served.dev });
      await page.waitForFunction(() => window.benchReady === true);
      const mount = await page.evaluate(() => window.benchMountMs);
      await page.evaluate(() => window.cmuxPaintFrame());
      const resize = pct(await framePass(page, "resize", FRAMES, 4), 0.95);
      await page.evaluate(() => {
        document.getElementById("root")!.style.width = "";
      });
      await page.evaluate(() => window.cmuxPaintFrame());
      const scroll = pct(await framePass(page, "scroll", FRAMES, 120), 0.95);
      await context.close();
      results[arm].push({ mount, resize, scroll });
      console.log(
        `terminal-history-offscreen round=${round} arm=${arm} n=${N} build=${served.dev ? "dev" : "production"} ` +
          `mount=${mount.toFixed(1)}ms resizeP95=${resize.toFixed(1)}ms scrollP95=${scroll.toFixed(1)}ms`,
      );
    }
  }
  for (const arm of ARMS) {
    const line = (["mount", "resize", "scroll"] as const)
      .map((key) => {
        const values = results[arm].map((row) => row[key]);
        return `${key} p50=${pct(values, 0.5).toFixed(1)}ms (${Math.min(...values).toFixed(1)}..${Math.max(...values).toFixed(1)})`;
      })
      .join(" ");
    console.log(`terminal-history-offscreen summary arm=${arm} n=${N} rounds=${ROUNDS} ${line}`);
  }
} finally {
  await browser.close();
  await served.close();
}
