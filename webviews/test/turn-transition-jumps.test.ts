// cmux-web-test-timeout: 420
// A running turn's transitions move nothing the reader sees by more than two thirds of a line in a
// 120 Hz frame (Leo, 2026-11-07: "the streaming text, and then, like, when you stream text, and then
// you get this burst, and then all of a sudden, then you start thinking. It's like, okay, the jumps
// are jarring. We want to minimize the jumps"). The page is send-stream-motion's
// (browser/send-stream-motion.harness.tsx: the real VirtualTranscript, its follow chase, a docked
// composer) on the frames' own clock (`clock: "frames"`, browser/frameClock.ts), so each run draws the
// same frames on any host; `?rows=1` samples every mounted row each frame after its layout. Each
// scripted turn (conversation/scriptedTurn.ts TRANSITION_TURNS) plays one of the transitions he named:
// - text-tool: the reply streams, then a tool call arrives, runs and finishes, and the reply goes on;
// - burst-thought: the reply streams, a burst lands most of a page at once, then a thought starts;
// - tool-group: four calls arrive one after another into one activity row;
// - steer-tools: the reader sends while a call runs; the steer waits, lands, the reply goes on;
// - thought-text: a thought streams, ends, and the reply's text starts under it;
// each then ends the turn. support/turnTransitionReport.ts measures each step's window: how far the
// rows the reader saw moved in one frame (the text above the change, and the live line and the rows
// under the reply against its text), pop-ins and reflows after a motion ended.
//
// Measured on this page at base (feat-cmux-next 29b1527bdde): the live line jumped 28 px when a call
// took its row, 56 px when a thought ended and the reply began, 66 px under a burst, 115 px when a
// steer came in under a running call, and the turn's footer 23-35 px as the turn ended; the text above
// moved 18-23 px in the frame a row arrived. Set CMUX_TURN_TRANSITION_DUMP=prefix to keep the samples.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Sample, Scenario } from "./browser/send-stream-motion.harness";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { TRANSITION_TURNS, type TransitionTurn } from "../src/agent-session/acpmux/conversation/scriptedTurn";
import { transitionReport } from "./support/turnTransitionReport";

await requireBrowserLane("turn-transition-jumps.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(180_000);
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn(
      "turn-transition-jumps: skipping, this Chrome draws no frames on the test's clock (run scripts/ci/ensure-system-chrome.sh and set CMUX_CHROME_HEADLESS_SHELL)",
    );
    describe.skip("turn transitions", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    // React's production build, as the app ships it, from send-stream-motion's dependency cache.
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

  async function samples(scenario: Scenario, look = ""): Promise<Sample[]> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const query = `clock=frames&rows=1${look ? `&tailGlide=${look}` : ""}`;
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?${query}`, { clock: "frames" });
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText("History answer 6.").waitFor();
      frames.start();
      const out = (await frames.page.evaluate(
        (scenario) =>
          (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
            scenario,
          }),
        scenario,
      )) as Sample[];
      await frames.stop();
      return out;
    } finally {
      await frames.close();
    }
  }

  /// One line of the reply at the chat font.
  const LINE_PX = 22.75;
  /// The most any row the reader sees moves in one frame of a transition: two thirds of a line
  /// (15.2 px). At base each turn's worst frame moved 20-115 px; on this branch it is 3.9-10.5 px
  /// (the most: the live line under a burst of the reply, and under a steer with its call).
  const MAX_TRANSITION_PX = (2 / 3) * LINE_PX;

  /// Each turn's steps, as scriptedTurn.ts names them.
  const STEPS: Record<TransitionTurn, string[]> = {
    "text-tool": ["tool", "tool-done", "segment", "end"],
    "burst-thought": ["burst", "thought", "end"],
    "tool-group": ["call-1", "call-2", "call-3", "call-4", "segment", "end"],
    "steer-tools": ["steer", "tool-done", "segment", "end"],
    "thought-text": ["thought", "text", "end"],
  };

  test.each([...TRANSITION_TURNS])(
    "%s: no frame moves what the reader sees by more than 2/3 of a line",
    async (scenario) => {
      const out = await samples(scenario);
      if (process.env.CMUX_TURN_TRANSITION_DUMP)
        await Bun.write(`${process.env.CMUX_TURN_TRANSITION_DUMP}-${scenario}.json`, JSON.stringify(out));
      const report = transitionReport(out, STEPS[scenario]);
      for (const window of report) console.log(`turn-transition ${scenario} ${JSON.stringify(window)}`);
      expect(report.map((window) => window.step)).toEqual(STEPS[scenario]);
      for (const window of report) {
        // The step, so a failure names it.
        expect({ step: window.step, worstPx: window.worstPx }).toEqual({
          step: window.step,
          worstPx: Math.min(window.worstPx, MAX_TRANSITION_PX),
        });
        // The stream's own frames (the reply's text growing and the chase bringing it home) keep to
        // the chase's bound: no frame moves more than a line (followChase CHASE_MAX_FRAME_LINES).
        expect({ step: window.step, streamPx: window.streamPx }).toEqual({
          step: window.step,
          streamPx: Math.min(window.streamPx, LINE_PX + 0.5),
        });
        // Nothing comes in at full ink, and nothing moves after the motion ended.
        expect(window.popIns).toEqual([]);
        expect(window.reflows).toBe(0);
      }
    },
  );

  // The gallery's looks on the same page (CMUX_TURN_TRANSITION_LOOKS=arrive,quick,glide,jump): each turn's
  // worst frame per look, for the PR's table.
  test.skipIf(!process.env.CMUX_TURN_TRANSITION_LOOKS)(
    "every tail-glide look (CMUX_TURN_TRANSITION_LOOKS)",
    async () => {
      for (const look of (process.env.CMUX_TURN_TRANSITION_LOOKS ?? "").split(",").filter(Boolean))
        for (const scenario of TRANSITION_TURNS) {
          const report = transitionReport(await samples(scenario, look), STEPS[scenario]);
          console.log(
            `turn-transition look ${look} ${scenario}: ${JSON.stringify(report.map((window) => [window.step, window.worstPx, window.jumpFrames]))}`,
          );
        }
    },
  );
});
