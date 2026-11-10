// cmux-web-test-timeout: 420
// Sending and a fast stream move the transcript smoothly at 120 Hz (Leo, 2026-11-07: "When it comes
// to sending messages, I feel like the jump, the jolt is a bit too jarring ... if you think about,
// like, what is satisfying at 120 hertz? That's what we want to aim at."). The page
// (browser/send-stream-motion.harness.tsx) draws the real transcript, sends a prompt from the latest
// row and streams a long Markdown reply fast; Chromium draws one frame every 8.33 ms
// (support/frames120.ts) and each frame's thread top is sampled after its layout. The page runs on
// the frames' own clock (`clock: "frames"`, browser/frameClock.ts): every frame is one 120 Hz slot
// after the last for its frame callbacks, timers and `performance.now`, so a loaded host draws the
// same frames later and the checks below read the same numbers on any host (on the wall clock a
// stall put more of the stream into one frame, and 2 in 20 runs failed the send). Each run prints a
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
    // The page on the frames' clock: what each frame draws follows from the frames before it, so a
    // loaded host draws the same motion later instead of more text and more pixels in one frame.
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?clock=frames&${query}`, { clock: "frames" });
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
      return analyze(samples, pacing.frameMs, pacing.dropped, MAX_TRAIL_PX, LINE_PX);
    } finally {
      await frames.close();
    }
  }

  /// One line of the reply at the chat font.
  const LINE_PX = 22.75;
  /// While the reply streams within the trail bound, under 0.85 of a line in 95 of 100 moving frames
  /// (18.2 px, CHASE_LAND_LINES, in every scenario; the most any such frame moves is 18.95 px).
  /// Taking each new block at once moved it 40-130 px in a frame before. The frames of a catch-up
  /// (a block landing past the bound and the frames bringing it back, up to a line each) are held
  /// by MAX_FRAME_PX and OVER_BOUND_FRAMES instead: the send's 12 blocks past the bound make 58 of
  /// its 358 moving frames, so a p95 over all of them counted those blocks, not how the stream moves.
  const P95_STREAM_FRAME_PX = 0.85 * LINE_PX;
  /// The most any frame moves: a line (followChase.ts CHASE_MAX_FRAME_LINES), and a pixel of
  /// rounding. A block landing before a frame's step and another after it in the same frame once
  /// moved the send 34.5 px in a frame (followChase.ts `stepped`).
  const MAX_FRAME_PX = LINE_PX + 1;
  /// Frames after the stream's last growth until the view rests at its end (lag 0, offset at the
  /// end, nothing moving): 30 frames is 250 ms, a spring's settle.
  const REST_FRAMES = 30;
  /// At rest the reply's newest line ends over the composer by the turn footer's band and the rest
  /// gap; more is room left blank under the rows.
  const REST_TAIL_PX = 160;
  /// The trail bound: two lines (followChase.ts CHASE_MAX_TRAIL_LINES). A block that lands past it
  /// is back within it in BURST_S (50 ms, six 120 Hz frames); the fixture's table lands its rows
  /// faster than a line a frame, so more lands while one catches up: the send's longest stretch is
  /// 10 frames (steer 5, tools 2). The unbounded chase trailed by up to 244 px for hundreds of ms.
  const MAX_TRAIL_PX = 2 * LINE_PX;
  const OVER_BOUND_FRAMES = 10;

  const SCENARIOS: Scenario[] = ["send", "tools", "steer"];

  test.each(SCENARIOS)(
    "%s: the default follow motion moves each frame a fraction of a line and rests pinned",
    async (scenario) => {
      const report = await measure("", scenario);
      console.log(`send-stream-motion default ${scenario}: ${JSON.stringify(report, null, 2)}`);
      // Nothing jumps: no frame of the turn moves the rows more than a line (a 120 Hz slot), and
      // most frames of the stream within the trail bound under 0.85 of a line.
      expect(report.jumpPx.max).toBeLessThanOrEqual(MAX_FRAME_PX);
      expect(report.jumpPx.streamCalmP95).toBeLessThanOrEqual(P95_STREAM_FRAME_PX);
      // The end of the turn moves nothing.
      expect(report.jumpPx.after).toBeLessThanOrEqual(1);
      // Never far behind the newest text on a fast stream: half the time within three lines.
      expect(report.lagPx.p50).toBeLessThanOrEqual(3 * LINE_PX);
      // Never more than two lines behind, except for at most 10 frames (83 ms at 120 Hz) after a
      // block lands.
      expect(report.overBound.maxFrames).toBeLessThanOrEqual(OVER_BOUND_FRAMES);
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
