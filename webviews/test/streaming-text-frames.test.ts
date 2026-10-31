// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A long reply streams smoothly (Leo, 2026-10-20): its text flows in on every frame at the rate it
// arrives, nothing already drawn above the line being written moves or changes kind, the view stays
// at the reply's latest line, and the frames keep their budget. The page (browser/streaming-text.harness.tsx)
// draws the real transcript over a chat's history with the bottom stack over its foot, and streams a
// 5,000-character Markdown reply (paragraphs, headings, lists, a code block, a table) at Claude's
// cadence and at Codex's, sampling every display frame. Each run prints its whole report.
//
// Both engines the app uses (WebKit draws the pane in cmux NEXT); one not installed skips. The
// frame budget is the main thread's work per frame: the script of the tasks between two frames
// (browser/streaming-text.clock.ts: React's renders, commits and effects with the layout they force,
// the reveal's frame callbacks, the row resize observers, the scroll handler, timers), and the
// style and layout left for the frame. Frame intervals are reported, not held: they measure the host as much as the
// page, and CI runs the dev-server browser files side by side (one frame in twelve came 33 ms apart
// there, job 119122855521). Pierre highlighting a closed fence (120 ms in Chromium, 1.1 s in WebKit
// on cmux16) is not the page's work and the frames it held are reported apart: this dev page has no
// highlight worker, and the app's page highlights in one (highlightPool.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import type { Cadence } from "../src/agent-session/acpmux/conversation/streamingTextFixture";
import type { StreamReport } from "./browser/streaming-text.harness";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("streaming-text-frames.test.ts", async () => {
  setDefaultTimeout(180_000);
  /// The budget a streaming reply keeps.
  const BUDGET = {
    /// The 95th percentile of a frame's work while the reply streams, and the most any frame takes.
    /// On cmux16 at load 20: 9-11 and 15-20 ms in Chromium, 6-7 and 15-26 ms in WebKit.
    p95WorkMs: 16.7,
    maxWorkMs: 50,
    /// Blocks above the one being written that move or change height.
    layoutShifts: 0,
    /// Blocks drawn as one kind, then another (a paragraph that becomes a list or a heading).
    tagFlips: 0,
    /// How far the view may rest from its end while it follows (VirtualTranscript's deadband).
    pinMaxPx: 4,
  };
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`streaming-text-frames: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("streaming text frames", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/streaming-text.html");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function stream(name: string, cadence: Cadence): Promise<StreamReport> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/streaming-text.html`);
    await page.waitForFunction(() => "__streamingText" in window);
    await page.getByText("History answer 6.").waitFor();
    // The page's first paints and the dev server's start-up settle before sampling.
    // fixed-wait: nothing marks the page's start-up as done
    await page.waitForTimeout(500);
    const report = await page.evaluate(
      (cadence) =>
        (
          window as unknown as { __streamingText: { run(options: { cadence: string }): Promise<unknown> } }
        ).__streamingText.run({ cadence }),
      cadence,
    );
    await page.close();
    return report as StreamReport;
  }

  /// What the report breaks of the work budget, one line each.
  function overWork(report: StreamReport): string[] {
    const over: string[] = [];
    const { totalMs, heaviest } = report.work;
    if (totalMs.max > BUDGET.maxWorkMs)
      over.push(`a frame's work took ${totalMs.max} ms (budget ${BUDGET.maxWorkMs}): ${JSON.stringify(heaviest)}`);
    if (totalMs.p95 > BUDGET.p95WorkMs) over.push(`p95 frame work ${totalMs.p95} ms (budget ${BUDGET.p95WorkMs})`);
    return over;
  }

  /// What the report breaks of the layout budget, one line each.
  function overLayout(report: StreamReport): string[] {
    const over: string[] = [];
    if (report.layout.shifts > BUDGET.layoutShifts)
      over.push(
        `${report.layout.shifts} layout shifts above the tail: ${report.layout.shiftEvents
          .slice(0, 5)
          .map((shift) => `${shift.tag}#${shift.index} "${shift.text}" top ${shift.top} height ${shift.height}`)
          .join("; ")}`,
      );
    if (report.layout.flips > BUDGET.tagFlips)
      over.push(
        `${report.layout.flips} tag flips: ${report.layout.flipEvents
          .slice(0, 5)
          .map((flip) => `#${flip.index} ${flip.from} "${flip.fromText}" -> ${flip.to} "${flip.text}"`)
          .join("; ")}`,
      );
    if (report.pin.maxFromEnd > BUDGET.pinMaxPx)
      over.push(`the view rested ${report.pin.maxFromEnd}px from its end (budget ${BUDGET.pinMaxPx})`);
    return over;
  }

  test.each(engines.flatMap(([name]) => [`${name} claude`, `${name} codex`]))(
    "%s: a long reply streams within the frame budget, with no shift above its tail",
    async (label) => {
      const [name, cadence] = label.split(" ") as [string, Cadence];
      const report = await stream(name, cadence);
      console.log(`streaming-text-frames ${label}: ${JSON.stringify(report, null, 2)}`);
      expect(overLayout(report)).toEqual([]);
      expect(report.longTasks?.duringStream ?? []).toEqual([]);
      // A frame's work is wall-clock time, so a host that starves the page can break it once (on
      // cmux16 at load 25, one run's grammar load took 850 ms, 40 times its usual 20). The work
      // budget fails when two runs in a row break it.
      if (overWork(report).length === 0) return;
      console.warn(`streaming-text-frames ${label}: over the work budget once (${overWork(report).join("; ")}); again`);
      const again = await stream(name, cadence);
      console.log(`streaming-text-frames ${label} again: ${JSON.stringify(again, null, 2)}`);
      expect(overLayout(again)).toEqual([]);
      expect(overWork(again)).toEqual([]);
    },
  );
});
