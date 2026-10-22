// cmux-web-test-timeout: 300
//
// Leo, 2026-10-20: "The diff viewer loads slowly ... Measure time-to-first-paint for a big diff,
// make it fast". This opens the real diff viewer (test/browser/diff-virtualization.html, the
// mountDiffSurface path a host's patch takes) on two big patches and holds it to a budget:
//
//   - `mixed`: 2,000 TypeScript files with every fifth line changed (about 10 MB of patch), and
//     a 1,500-line rewrite after them;
//   - `huge`: one generated 1,000,000-line bundle (about 60 MB of patch) ahead of 50 small files.
//
// For each it reads, after every painted frame from the moment the harness's patch is ready (`patch-ready`):
//   - firstRow: the first diff row is drawn inside the viewer (plain text or highlighted);
//   - firstHighlight: the first row is drawn with syntax colors.
// And on `mixed` the first row must draw while most of the patch is still streaming (FIRST_ROW_SHARE
// of the time to the last file), which holds on any machine speed.
//
// This file's own numbers on huge-blue (dev server, best of two runs), feat-cmux-next 7a4b464b375
// then this change: `mixed` first row 1,129 -> 456 ms, first highlight 1,414 -> 1,086 ms, first row
// at 78% -> 21% of the stream; `huge` first row 5,896 -> 1,149 ms, first highlight 5,959 ->
// 1,366 ms. Before, the stream re-flattened the whole buffered patch for every 256 KB chunk of one
// big file, the highlight pool started only with the first files, and rows drew only once every
// worker had compiled Shiki's WASM. The budgets are about three times the new numbers, for a slower
// CI runner; the old behavior misses the `huge` budgets, the share and the plain-rows check.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { stopDevServer } from "./support/devServer";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("diff-paint-perf.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("diff-paint-perf: skipping (run `bunx playwright install chromium`)");
    describe.skip("diff paint perf", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  /// Budgets from the patch being ready (see the header).
  const BUDGETS = {
    mixed: { firstRow: 1_500, firstHighlight: 3_300 },
    huge: { firstRow: 3_500, firstHighlight: 4_500 },
  } as const;
  /// `mixed`: the first row draws before this share of the time the last file streams in.
  const FIRST_ROW_SHARE = 0.6;
  const RUNS = 2;

  let server: ChildProcess | null = null;
  let base = "";
  let browser: Browser | undefined;

  beforeAll(async () => {
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
    });
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    await warmDevServer(base, "/test/browser/diff-virtualization.html");
    browser = await chromium.launch({ headless: true });
  }, 240_000);

  afterAll(async () => {
    await browser?.close();
    stopDevServer(server);
  });

  /// Runs in the page before its scripts: marks, after each painted frame (installPaintedFrames),
  /// the frame that first drew a row inside the viewer, the first that drew a highlighted row, and
  /// the first after every file had streamed.
  function probe() {
    const first: Record<string, number> = {};
    (window as unknown as { __diffPaint: Record<string, number> }).__diffPaint = first;
    window.cmuxAfterPaint((frame) => {
      const mark = (name: string) => {
        if (first[name] == null) first[name] = frame;
      };
      const viewer = document.querySelector("#viewer")?.getBoundingClientRect();
      if (viewer != null) {
        for (const host of document.querySelectorAll("#viewer diffs-container")) {
          for (const line of (host as HTMLElement).shadowRoot?.querySelectorAll("[data-line]") ?? []) {
            const rect = line.getBoundingClientRect();
            if (rect.height === 0 || rect.bottom <= viewer.top || rect.top >= viewer.bottom) continue;
            mark("firstRow");
            if (line.querySelector("span[style*='--diffs-token']")) mark("firstHighlight");
            break;
          }
        }
      }
      if (document.body.dataset.streamElapsedMs) mark("complete");
      return first.firstRow == null || first.firstHighlight == null || first.complete == null;
    });
  }

  type Run = {
    firstRow: number;
    firstHighlight: number;
    complete: number;
    plainBeforeWorkers: string;
    files: number;
  };

  async function open(fixture: keyof typeof BUDGETS): Promise<Run> {
    const context = await browser!.newContext({ viewport: { width: 1400, height: 900 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await page.addInitScript(probe);
    await page.goto(`${base}/test/browser/diff-virtualization.html?fixture=${fixture}`);
    await page.waitForFunction(
      () => {
        const first = (window as unknown as { __diffPaint?: Record<string, number> }).__diffPaint;
        return first?.firstRow != null && first.firstHighlight != null && first.complete != null;
      },
      null,
      { timeout: 60_000, polling: 50 },
    );
    const result = await page.evaluate(() => {
      const first = (window as unknown as { __diffPaint: Record<string, number> }).__diffPaint;
      const ready = performance.getEntriesByName("patch-ready")[0]?.startTime ?? 0;
      return {
        firstRow: Math.round(first.firstRow! - ready),
        firstHighlight: Math.round(first.firstHighlight! - ready),
        complete: Math.round(first.complete! - ready),
        plainBeforeWorkers: document.documentElement.dataset.cmuxDiffPlainBeforeWorkers ?? "",
        files: Number(document.body.dataset.streamFileCount),
      };
    });
    await context.close();
    return result;
  }

  for (const fixture of Object.keys(BUDGETS) as (keyof typeof BUDGETS)[]) {
    test(`${fixture}: the first rows draw, then their colors, inside the budget`, async () => {
      const budget = BUDGETS[fixture];
      const runs: Run[] = [];
      for (let run = 0; run < RUNS; run += 1) runs.push(await open(fixture));
      console.log(`diff-paint-perf ${fixture}: ${JSON.stringify(runs)} budget ${JSON.stringify(budget)}`);
      // The best of the runs: the first one also pays the dev server's cold module cache.
      const best = (key: "firstRow" | "firstHighlight") => Math.min(...runs.map((run) => run[key]));
      expect(runs.every((run) => run.files === (fixture === "mixed" ? 2001 : 51))).toBe(true);
      // The pool drew plain rows before its workers were up (WorkerRenderOptionsSync.tsx); a
      // @pierre/diffs that renamed what that reads leaves this unset.
      expect(runs.map((run) => run.plainBeforeWorkers)).toEqual(runs.map(() => "drawn"));
      expect(best("firstRow")).toBeLessThan(budget.firstRow);
      expect(best("firstHighlight")).toBeLessThan(budget.firstHighlight);
      if (fixture === "mixed") {
        expect(Math.min(...runs.map((run) => run.firstRow / run.complete))).toBeLessThan(FIRST_ROW_SHARE);
      }
    });
  }
});
