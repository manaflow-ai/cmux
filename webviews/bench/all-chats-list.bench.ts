// l10n-allow-file: benchmark output, not shipped UI.
// The chat lists a person with many workspaces scrolls and clicks, at N chats, on Chromium: a production build
// (React Compiler, minified, React's profiling build) of bench/all-chats-list/, the real HistoryScreen and the New
// Tab page's AllChatsList over a stand-in chat index (Leo, 2026-11-08: "adding evals and benches so teammates can
// see stuff"; the ask named the sidebar with 500 workspaces). Two arms, each a fresh page per round:
//   history  the History page (the sidebar's History dot): N indexed chats, paged 100 at a time, virtualized.
//   live     the New Tab page's All chats: N live chats (one per workspace with an agent) above N indexed ones.
// Per arm, as medians over the rounds:
//   mount            render() until the first painted frame with rows (ms);
//   scroll.work_ms   main-thread time of each frame while the list scrolls 60 px a frame top to bottom: from
//                    the frame's first scroll handler or frame callback to the task after it painted (p50/p95);
//   scroll.react_ms  React commit time (Profiler actualDuration) in each of those frames (p50/p95);
//   open_press       a row's press (the mousedown's timeStamp) until the first painted frame after the press asked
//                    the host to open its chat (the busy row painted), the median of five rows a round. Event
//                    Timing is not used: it reports nothing under 16 ms.
//   bun bench/all-chats-list.bench.ts [rounds=3] [n=500]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Page } from "playwright";
import { reactWithCompiler } from "../reactCompiler.mjs";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow, TARGET_MS } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 3);
const N = Number(process.argv[3] ?? 500);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(N) || N < 10)
  throw new Error("usage: all-chats-list.bench.ts [rounds>=1] [n>=10]");
const ARMS = ["history", "live"] as const;
type Arm = (typeof ARMS)[number];
/// The scroller each arm's rows move in.
const SCROLLER: Record<Arm, string> = { history: ".nt-all-list", live: ".nt-screen" };
const STEP_PX = 60;
const PRESSES = 5;

const webviews = path.resolve(import.meta.dir, "..");
const sharedStyles = path.join(webviews, "src/agent-session/shared/styles.css");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "all-chats-list-bench-"));
const { build } = await import("vite");
await build({
  configFile: false,
  root: path.join(import.meta.dir, "all-chats-list"),
  base: "./",
  logLevel: "error",
  // The profiling build of react-dom: production React whose Profiler reports commit times.
  resolve: { alias: [{ find: /^react-dom\/client$/, replacement: "react-dom/profiling" }] },
  plugins: [
    {
      name: "bench-shared-styles",
      enforce: "pre",
      transform(code: string, id: string) {
        if (id.split("?")[0] !== sharedStyles) return null;
        return { code: code.replace(/^@import .*$/gm, ""), map: null };
      },
    },
    ...reactWithCompiler(),
  ],
  build: { outDir: out, emptyOutDir: true },
});
const statics = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    const pathname = new URL(request.url).pathname;
    const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
});
const browser = await chromium.launch({
  ...(process.env.CMUX_CHROME_HEADLESS_SHELL
    ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
    : { channel: "chrome" }),
  headless: true,
});

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;
const median = (values: number[]) => pct(values, 0.5);

type Round = {
  mount: number;
  workP50: number;
  workP95: number;
  reactP50: number;
  reactP95: number;
  press: number;
  frames: number;
  domRows: number;
  opens: number;
};

/// Scrolls the arm's scroller to its end once, so every page of the index is read before the measured pass.
async function readAllPages(page: Page, scroller: string) {
  for (let pass = 0; pass < 40; pass++) {
    const done = await page.evaluate(
      ({ selector, n }) =>
        window
          .cmuxPaintFrame(() => {
            const element = document.querySelector<HTMLElement>(selector)!;
            element.scrollTop = 1e7;
          })
          .then(
            () => document.querySelectorAll(".nt-all-item:not(.is-loader)").length > 0 && window.benchPages * 100 >= n,
          ),
      { selector: scroller, n: N },
    );
    if (done) break;
    await page.waitForTimeout(30);
  }
  await page.waitForTimeout(100);
  await page.evaluate(
    (selector) =>
      window.cmuxPaintFrame(() => {
        document.querySelector<HTMLElement>(selector)!.scrollTop = 0;
      }),
    scroller,
  );
  await page.waitForTimeout(300);
}

/// One pass top to bottom, STEP_PX a frame: each frame's main-thread time and React commit time.
function scrollPass(page: Page, scroller: string) {
  return page.evaluate(
    ({ selector, step }) =>
      new Promise<{ work: number[]; react: number[]; domRows: number }>((resolve) => {
        const element = document.querySelector<HTMLElement>(selector)!;
        const end = element.scrollHeight - element.clientHeight;
        const frames: { start: number; end: number }[] = [];
        let firstHandler = Number.POSITIVE_INFINITY;
        // A capture listener on the window hears the scroller's scroll event, the frame's first work.
        const onScroll = () => {
          if (firstHandler === Number.POSITIVE_INFINITY) firstHandler = performance.now();
        };
        addEventListener("scroll", onScroll, { capture: true, passive: true });
        let top = 0;
        let started = 0;
        const commitsFrom = window.benchCommits.length;
        let domRows = 0;
        window.cmuxAfterPaint(
          () => {
            frames.push({ start: Math.min(firstHandler, started), end: performance.now() });
            firstHandler = Number.POSITIVE_INFINITY;
            domRows = Math.max(domRows, document.querySelectorAll(".nt-all-row").length);
            if (top < end) return true;
            removeEventListener("scroll", onScroll, { capture: true });
            const commits = window.benchCommits.slice(commitsFrom);
            // The first frame only sets the first offset; its scroll is handled in the next frame.
            const measured = frames.slice(1);
            resolve({
              work: measured.map((frame) => frame.end - frame.start),
              react: measured.map((frame) =>
                commits
                  .filter(([at]) => at >= frame.start && at <= frame.end)
                  .reduce((sum, [, duration]) => sum + duration, 0),
              ),
              domRows,
            });
            return false;
          },
          () => {
            started = performance.now();
            top = Math.min(end, top + step);
            element.scrollTop = top;
          },
        );
      }),
    { selector: scroller, step: STEP_PX },
  );
}

async function round(arm: Arm): Promise<Round> {
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  const page = await context.newPage();
  await installPaintedFrames(page);
  await page.goto(`http://127.0.0.1:${statics.port}/#arm=${arm}&n=${N}`);
  await page.waitForFunction(() => window.benchReady === true);
  const mount = await page.evaluate(
    () =>
      new Promise<number>((resolve) =>
        window.cmuxAfterPaint(() => {
          if (!document.querySelector(".nt-all-row")) return true;
          resolve(performance.now() - window.benchRenderAt);
          return false;
        }),
      ),
  );
  const scroller = SCROLLER[arm];
  await readAllPages(page, scroller);
  const pass = await scrollPass(page, scroller);
  await page.waitForTimeout(200);
  // Presses on rows in view, from the middle of the list.
  await page.evaluate((selector) => {
    const element = document.querySelector<HTMLElement>(selector)!;
    const middle = element.scrollHeight / 2;
    return window.cmuxPaintFrame(() => {
      element.scrollTop = middle;
    });
  }, scroller);
  await page.waitForTimeout(300);
  const presses: number[] = [];
  for (let index = 0; index < PRESSES; index++) {
    const box = await page.evaluate((nth) => {
      const visible = [...document.querySelectorAll<HTMLElement>(".nt-all-row")].filter((row) => {
        const rect = row.getBoundingClientRect();
        return rect.top > 80 && rect.bottom < innerHeight - 80;
      });
      const rect = visible[(nth * 3) % visible.length]!.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    }, index);
    await page.mouse.move(box.x, box.y);
    await page.waitForTimeout(50);
    // The page's window capture hears the press before the row's handler; the first painted frame after the
    // host was asked ends it.
    await page.evaluate(() => {
      window.benchPress = new Promise<number>((resolve, reject) => {
        const opens = window.benchOpens;
        const deadline = setTimeout(() => reject(new Error("the press opened nothing within 5 s")), 5000);
        addEventListener(
          "mousedown",
          (event) => {
            const pressedAt = event.timeStamp;
            window.cmuxAfterPaint(() => {
              if (window.benchOpens === opens) return true;
              clearTimeout(deadline);
              resolve(performance.now() - pressedAt);
              return false;
            });
          },
          { capture: true, once: true },
        );
      });
    });
    await page.mouse.down();
    await page.mouse.up();
    presses.push(await page.evaluate(() => window.benchPress));
    await page.waitForTimeout(100);
  }
  const opens = await page.evaluate(() => window.benchOpens);
  await context.close();
  return {
    mount,
    workP50: pct(pass.work, 0.5),
    workP95: pct(pass.work, 0.95),
    reactP50: pct(pass.react, 0.5),
    reactP95: pct(pass.react, 0.95),
    press: median(presses),
    frames: pass.work.length,
    domRows: pass.domRows,
    opens,
  };
}

try {
  for (const arm of ARMS) {
    const rounds: Round[] = [];
    for (let index = 0; index < ROUNDS; index++) rounds.push(await round(arm));
    const of = (pick: (r: Round) => number) => median(rounds.map(pick));
    console.log(
      `all-chats-list ${arm} n=${N} rounds=${ROUNDS} mountMs=${of((r) => r.mount).toFixed(1)} ` +
        `scrollWork=${of((r) => r.workP50).toFixed(1)}/${of((r) => r.workP95).toFixed(1)} ` +
        `scrollReact=${of((r) => r.reactP50).toFixed(2)}/${of((r) => r.reactP95).toFixed(2)} ` +
        `pressMs=${of((r) => r.press).toFixed(1)} frames=${of((r) => r.frames)} domRows=${of((r) => r.domRows)} ` +
        `opens=${of((r) => r.opens)}`,
    );
    const name = `all_chats.${arm}_${N}`;
    // The median of rounds, as both p50 and p95 (perfRow.ts) for one-number rows.
    perfRow({
      name: `${name}.mount`,
      p50: of((r) => r.mount),
      p95: of((r) => r.mount),
      target: TARGET_MS.response,
    });
    perfRow({
      name: `${name}.scroll.work_ms`,
      p50: of((r) => r.workP50),
      p95: of((r) => r.workP95),
      target: TARGET_MS.frameWork,
      floor: 1,
    });
    perfRow({
      name: `${name}.scroll.react_ms`,
      p50: of((r) => r.reactP50),
      p95: of((r) => r.reactP95),
      target: TARGET_MS.frameWork,
      floor: 0.5,
    });
    // A frame (16.7 ms headless) is the step a press can move by.
    perfRow({
      name: `${name}.open_press`,
      p50: of((r) => r.press),
      p95: of((r) => r.press),
      target: TARGET_MS.response,
      floor: 4,
    });
  }
} finally {
  await browser.close();
  await statics.stop(true);
  fs.rmSync(out, { recursive: true, force: true });
}
