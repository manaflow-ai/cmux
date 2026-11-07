// cmux-web-test-timeout: 420
// Sending and a fast stream move the transcript smoothly at 120 Hz (Leo, 2026-11-07: "When it comes
// to sending messages, I feel like the jump, the jolt is a bit too jarring ... if you think about,
// like, what is satisfying at 120 hertz? That's what we want to aim at."). The page
// (browser/send-stream-motion.harness.tsx) draws the real transcript, sends a prompt from the latest
// row and streams a long Markdown reply fast; Chromium draws one frame every 8.33 ms
// (support/frames120.ts) and each frame's thread top is sampled after its layout. Each run prints a
// report: dropped frames, frame time, the largest move of the thread in one frame (send and stream
// apart), how far the drawn rows trailed their layout, and the frames from the stream's last
// growth until the view rests at its end.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import type { Sample, Scenario } from "./browser/send-stream-motion.harness";
import { analyze, type MotionReport } from "./support/sendStreamMotionReport";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("send-stream-motion.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-stream-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("send and stream motion", () => test("no chromium", () => {}));
    return;
  }
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn(
      "send-stream-motion: skipping, this Chrome draws no frames on the test's clock (run scripts/ci/ensure-system-chrome.sh and set CMUX_CHROME_HEADLESS_SHELL)",
    );
    describe.skip("send and stream motion", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    // React's production build, as the app ships it (its development build's checks doubled every
    // frame's work), from a dependency cache of its own so other dev-server files keep theirs.
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-send-stream-motion"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  async function measure(query: string, scenario: Scenario = "send"): Promise<MotionReport> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?${query}`);
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText("History answer 6.").waitFor();
      frames.start();
      const samples = (await frames.page.evaluate(
        (scenario) =>
          (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
            scenario,
          }),
        scenario,
      )) as Sample[];
      const pacing = await frames.stop();
      if (process.env.CMUX_SEND_STREAM_DUMP)
        await Bun.write(
          `${process.env.CMUX_SEND_STREAM_DUMP}-${query || "default"}-${scenario}.json`,
          JSON.stringify(samples),
        );
      return analyze(samples, pacing.frameMs, pacing.dropped);
    } finally {
      await frames.close();
    }
  }

  /// One line of the reply at the chat font.
  const LINE_PX = 22.75;
  /// The most the thread may move in one 120 Hz frame while a prompt sends (or steers): 16 px. At
  /// the chase's speed limit a frame moves 7 px; a steer that lands 150 px of rows (the prompt and
  /// the reply's footer) catches up faster for a few frames (followChase.ts CATCH_UP_PX), 12-13 px.
  /// The send moved the transcript 76-132 px in one frame before.
  const MAX_SEND_FRAME_PX = 16;
  /// While the reply streams: at most a line in any frame, and under half a line in 95 of 100
  /// moving frames. Taking each new block at once moved it 40-130 px in a frame. The fixture's
  /// table and code card grow faster than any frame's step (1,500 px/s and more), so the chase
  /// speeds up by what it trails past two lines (followChase.ts CATCH_UP_PX).
  const MAX_STREAM_FRAME_PX = LINE_PX;
  const P95_STREAM_FRAME_PX = LINE_PX / 2;
  /// Frames after the stream's last growth until the view rests at its end (lag 0, offset at the
  /// end, nothing moving): 30 frames is 250 ms, a spring's settle.
  const REST_FRAMES = 30;
  /// At rest the reply's newest line ends over the composer by the turn footer's band and the rest
  /// gap; more is room left blank under the rows.
  const REST_TAIL_PX = 160;

  const SCENARIOS: Scenario[] = ["send", "tools", "steer"];

  test.each(SCENARIOS)(
    "%s: the default follow motion moves each frame a fraction of a line and rests pinned",
    async (scenario) => {
      const report = await measure("", scenario);
      console.log(`send-stream-motion default ${scenario}: ${JSON.stringify(report, null, 2)}`);
      // The send and a steer: the bubble, the rows above it and the composer's room move as one.
      expect(report.jumpPx.send).toBeLessThanOrEqual(MAX_SEND_FRAME_PX);
      expect(report.jumpPx.stream).toBeLessThanOrEqual(MAX_STREAM_FRAME_PX);
      expect(report.jumpPx.streamP95).toBeLessThanOrEqual(P95_STREAM_FRAME_PX);
      // Thoughts and tool calls arriving and finishing: no move larger than a line in a frame.
      for (const [phase, entry] of Object.entries(report.byPhase))
        expect({ phase, maxPx: Math.min(entry.maxPx, LINE_PX + 0.01) }).toEqual({ phase, maxPx: entry.maxPx });
      // The end of the turn moves nothing.
      expect(report.jumpPx.after).toBeLessThanOrEqual(1);
      // Never far behind the newest text on a fast stream: half the time within three lines.
      expect(report.lagPx.p50).toBeLessThanOrEqual(3 * LINE_PX);
      expect(report.restsAtEnd).toBe(true);
      expect(report.restFramesAfterStream).toBeLessThanOrEqual(REST_FRAMES);
      // A steer's reply ends 10 px lower than a send's, the same with every arm and motion off.
      expect(report.tailAtEnd).toBeGreaterThanOrEqual(-LINE_PX / 2);
      expect(report.tailAtEnd).toBeLessThanOrEqual(REST_TAIL_PX);
    },
  );

  test("with motion off the view takes each step at once and never trails its layout", async () => {
    const report = await measure("motion=off");
    console.log(`send-stream-motion motion off: ${JSON.stringify(report, null, 2)}`);
    expect(report.lagPx.max).toBe(0);
    expect(report.atOnce).toBeGreaterThan(0);
    expect(report.restsAtEnd).toBe(true);
    expect(report.tailAtEnd).toBeGreaterThanOrEqual(-1);
  });

  // The before/after table for the PR: every arm of the follow-motion experiment on the same page.
  test.skipIf(!process.env.CMUX_SEND_STREAM_ARMS)("every follow-motion arm (CMUX_SEND_STREAM_ARMS=1)", async () => {
    for (const arm of (process.env.CMUX_SEND_STREAM_ARMS ?? "").split(",").filter(Boolean)) {
      for (const scenario of SCENARIOS) {
        const report = await measure(`arm=${arm}`, scenario);
        console.log(`send-stream-motion arm ${arm} ${scenario}: ${JSON.stringify(report)}`);
      }
    }
  });
});
