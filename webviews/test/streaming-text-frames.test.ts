// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A long reply streams smoothly (Leo, 2026-10-20): its text flows in on every frame at the rate it
// arrives, nothing already drawn above the line being written moves or changes kind, the view stays
// at the reply's latest line, and the frames keep their budget. The page (browser/streaming-text.harness.tsx)
// draws the real transcript over a chat's history with the bottom stack over its foot, and streams a
// 5,000-character Markdown reply (paragraphs, headings, lists, a code block, a table) at Claude's
// cadence and at Codex's, sampling every display frame. Each run prints its whole report.
//
// Both engines the app uses (WebKit draws the pane in cmux NEXT); one not installed skips. Frame
// timing is held to its budget in Chromium only; WebKit's is reported.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import type { Cadence, StreamReport } from "./browser/streaming-text.harness";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("streaming-text-frames.test.ts", async () => {
  setDefaultTimeout(180_000);
  /// The budget a streaming reply keeps.
  const BUDGET = {
    /// Chromium only: no frame interval longer than this while the reply streams.
    maxFrameMs: 50,
    /// Chromium only: the 95th percentile frame interval.
    p95FrameMs: 20,
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

  /// What the report breaks of the budget, one line each.
  function overBudget(name: string, report: StreamReport): string[] {
    const over: string[] = [];
    if (name === "chromium" && report.frames.intervalMs.max > BUDGET.maxFrameMs)
      over.push(`a frame took ${report.frames.intervalMs.max} ms (budget ${BUDGET.maxFrameMs})`);
    if (name === "chromium" && report.frames.intervalMs.p95 > BUDGET.p95FrameMs)
      over.push(`p95 frame interval ${report.frames.intervalMs.p95} ms (budget ${BUDGET.p95FrameMs})`);
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
      expect(overBudget(name, report)).toEqual([]);
    },
  );
});
