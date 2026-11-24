/// <reference types="bun" />
// The team board's perf harness: open, scroll and live-update cost at 3, 100, 1,000 and 5,000
// machines, "before" (every row in the DOM, the way the Cloud page lists machines) and "after"
// (the shipped windowed list), from one production build in headless Chromium.
//
//   bun bench/board/run.ts [--sizes 3,100,1000,5000] [--runs 3] [--cpu-throttle 4] [--json out.json] [--no-build]
//
// Per size and mode it reports: open (ms from mount to the first painted frame with rows, median of
// runs), rows in the DOM, main-thread work per scroll step (Chrome's TaskDuration over 120 one-screen
// steps, divided by the steps), p95 frame interval while scrolling, and the same two while 100
// generated changes a second arrive for 3 s. Main-thread work is CPU time the page spent, which does
// not depend on the display's refresh rate the way frame intervals do.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, type CDPSession, type Page } from "playwright";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const outDir = process.env.CMUX_BOARD_BENCH_OUT_DIR ?? "/tmp/cmux-board-bench";

const args = process.argv.slice(2);
const option = (name: string, fallback: string) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 && args[index + 1] ? args[index + 1]! : fallback;
};
const sizes = option("sizes", "3,100,1000,5000").split(",").map(Number);
const runs = Number(option("runs", "3"));
const throttle = Number(option("cpu-throttle", "1"));
const jsonOut = args.includes("--json") ? option("json", "board-bench.json") : null;

if (!args.includes("--no-build")) {
  const build = spawnSync("node_modules/.bin/vp", ["build", "-c", "vite.config.board-bench.ts"], {
    cwd: webviews,
    stdio: "inherit",
    env: { ...process.env, CMUX_BOARD_BENCH_OUT_DIR: outDir },
  });
  if (build.status !== 0) process.exit(build.status ?? 1);
}
const htmlPath = path.join(outDir, "bench/board/harness.html");
if (!existsSync(htmlPath)) throw new Error(`no harness build at ${htmlPath}`);

const types: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".wasm": "application/wasm",
};
const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  fetch(request) {
    const url = new URL(request.url);
    const file = path.join(outDir, decodeURIComponent(url.pathname));
    if (!file.startsWith(outDir) || !existsSync(file)) return new Response("not found", { status: 404 });
    return new Response(readFileSync(file), {
      headers: { "content-type": types[path.extname(file)] ?? "application/octet-stream" },
    });
  },
});
const pageUrl = `http://127.0.0.1:${server.port}/bench/board/harness.html`;

type Metrics = Record<string, number>;
async function metrics(cdp: CDPSession): Promise<Metrics> {
  const { metrics: list } = await cdp.send("Performance.getMetrics");
  return Object.fromEntries(list.map((metric: { name: string; value: number }) => [metric.name, metric.value]));
}

const quantile = (values: number[], q: number) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};
const median = (values: number[]) => quantile(values, 0.5);
const round = (value: number, digits = 2) => Number(value.toFixed(digits));

interface Result {
  size: number;
  mode: "before" | "after";
  openMs: number;
  openTaskMs: number;
  rows: number;
  domNodes: number;
  heapMB: number;
  scrollTaskMsPerStep: number;
  scrollP95FrameMs: number;
  updatesTaskMsPerSecond: number;
  updatesP95FrameMs: number;
  updatesLongFrames: number;
}

async function measure(page: Page, cdp: CDPSession, size: number, windowed: boolean): Promise<Result> {
  const opens: number[] = [];
  const openTasks: number[] = [];
  let rows = 0;
  let domNodes = 0;
  let heapMB = 0;
  for (let run = 0; run < runs; run += 1) {
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.boardHarness !== undefined, undefined, { timeout: 30_000 });
    await page.evaluate((n) => window.boardHarness.prepare(n), size);
    await cdp.send("HeapProfiler.collectGarbage");
    const before = await metrics(cdp);
    opens.push(await page.evaluate((w) => window.boardHarness.mount(w), windowed));
    const after = await metrics(cdp);
    openTasks.push((after.TaskDuration! - before.TaskDuration!) * 1000);
    rows = await page.evaluate(() => window.boardHarness.rows());
    domNodes = after.Nodes!;
    heapMB = after.JSHeapUsedSize! / 1024 / 1024;
  }
  // Scroll: 120 steps of one screen (wrapping), one per frame.
  const steps = 120;
  const scrollBefore = await metrics(cdp);
  const scrollFrames = await page.evaluate((s) => window.boardHarness.scroll(s, 640), steps);
  const scrollAfter = await metrics(cdp);
  // Live: 100 changes a second for 3 s.
  const updatesBefore = await metrics(cdp);
  const updateFrames = await page.evaluate(() => window.boardHarness.updates(100, 3000));
  const updatesAfter = await metrics(cdp);
  await page.evaluate(() => window.boardHarness.unmount());
  return {
    size,
    mode: windowed ? "after" : "before",
    openMs: round(median(opens), 1),
    openTaskMs: round(median(openTasks), 1),
    rows,
    domNodes,
    heapMB: round(heapMB, 1),
    scrollTaskMsPerStep: round(((scrollAfter.TaskDuration! - scrollBefore.TaskDuration!) * 1000) / steps),
    scrollP95FrameMs: round(quantile(scrollFrames, 0.95), 1),
    updatesTaskMsPerSecond: round(((updatesAfter.TaskDuration! - updatesBefore.TaskDuration!) * 1000) / 3, 1),
    updatesP95FrameMs: round(quantile(updateFrames, 0.95), 1),
    updatesLongFrames: updateFrames.filter((ms) => ms > 50).length,
  };
}

const browser = await chromium.launch({ headless: true });
const results: Result[] = [];
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  page.on("pageerror", (error) => console.error(`page error: ${error.message}`));
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
  if (throttle > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
  for (const size of sizes)
    for (const windowed of [false, true]) {
      const result = await measure(page, cdp, size, windowed);
      results.push(result);
      console.log(JSON.stringify(result));
    }
} finally {
  await browser.close();
  void server.stop(true);
}

const header = [
  "machines",
  "mode",
  "open ms",
  "open task ms",
  "rows in DOM",
  "DOM nodes",
  "heap MB",
  "scroll task ms/step",
  "scroll p95 frame ms",
  "live task ms/s",
  "live p95 frame ms",
  "live frames >50ms",
];
const table = [
  `| ${header.join(" | ")} |`,
  `| ${header.map(() => "---").join(" | ")} |`,
  ...results.map(
    (r) =>
      `| ${[r.size, r.mode, r.openMs, r.openTaskMs, r.rows, r.domNodes, r.heapMB, r.scrollTaskMsPerStep, r.scrollP95FrameMs, r.updatesTaskMsPerSecond, r.updatesP95FrameMs, r.updatesLongFrames].join(" | ")} |`,
  ),
];
console.log(`\nChromium headless, CPU throttle ${throttle}x, ${runs} opens per cell (median)\n`);
console.log(table.join("\n"));
if (jsonOut) writeFileSync(jsonOut, JSON.stringify({ throttle, runs, results }, null, 2));
