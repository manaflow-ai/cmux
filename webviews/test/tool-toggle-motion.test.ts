// cmux-web-test-timeout: 300
// A tool call's line opened and closed while the reply streams on under it is one motion each time:
// the line stays on its pixel, the rows over it hold still, the rows under it ride on its details' foot
// in the same frames, a close clicked before the open ended turns the same motion back, and nothing
// moves once it rests (Leo, 2026-11-06: "the entire tool call expansion apparatus is borked ... things
// clash with other things with animations going haywire -- this is of course during heavy load, but
// there are a bunch of things which i think are just way too discontinuous and also way too
// jittery/sensitive. and it's just slow.").
//
// The page is send-stream-motion's (browser/send-stream-motion.harness.tsx: the real VirtualTranscript,
// its follow chase, a docked composer) at 120 Hz on the frames' own clock (`clock: "frames"`), with
// every mounted row sampled each frame (`?rows=1`). The scripted turn `tool-toggle`
// (conversation/scriptedTurn.ts) runs a call that prints, then streams the reply's next segment while
// the page clicks the call's line four times (TOGGLE_CLICKS: open, close, open, and a close 60 ms into
// that open). support/toolToggleReport.ts measures each click's window.
// Set CMUX_TOOL_TOGGLE_DUMP=prefix to keep the samples.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Sample } from "./browser/send-stream-motion.harness";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { TOGGLE_CLICKS } from "../src/agent-session/acpmux/conversation/scriptedTurn";
import { toggleReport } from "./support/toolToggleReport";

await requireBrowserLane("tool-toggle-motion.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(180_000);
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn("tool-toggle-motion: skipping, this Chrome draws no frames on the test's clock");
    describe.skip("tool toggle", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
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

  /// `wall`: on the wall clock (no `clock=frames`), so a frame whose work runs long misses slots, as
  /// on a loaded host.
  async function samples(extra = "", wall = false): Promise<Sample[]> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const frames = await open120Hz(
      `http://127.0.0.1:${port}${PAGE}?rows=1${wall ? "" : "&clock=frames"}${extra}`,
      wall ? {} : { clock: "frames" },
    );
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText("History answer 6.").waitFor();
      frames.start();
      const out = (await frames.page.evaluate(() =>
        (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
          scenario: "tool-toggle",
        }),
      )) as Sample[];
      await frames.stop();
      return out;
    } finally {
      await frames.close();
    }
  }

  const STEPS = TOGGLE_CLICKS.map((click) => click.step);
  /// The fold's length (conversation.css `--cv-fold-duration`, the settle: 180 ms) and three frames of
  /// slack for the click's own frame and the last measure.
  const REST_MS = 180 + 25;

  test("a call opened and closed during a stream moves as one motion each time", async () => {
    const out = await samples();
    if (process.env.CMUX_TOOL_TOGGLE_DUMP)
      await Bun.write(`${process.env.CMUX_TOOL_TOGGLE_DUMP}.json`, JSON.stringify(out));
    const report = toggleReport(out, STEPS);
    for (const window of report) console.log(`tool-toggle ${JSON.stringify(window)}`);
    expect(report.map((window) => [window.step, window.open])).toEqual([
      ["open", true],
      ["close", false],
      ["open-again", true],
      ["reverse", false],
      ["drag", false],
    ]);
    for (const window of report) {
      // The step, so a failure names it.
      const got = { step: window.step, anchorPx: window.anchorPx, tearPx: window.tearPx, reversals: window.reversals };
      expect(got).toEqual({
        step: window.step,
        anchorPx: Math.min(window.anchorPx, 0.5),
        tearPx: Math.min(window.tearPx, 0.5),
        reversals: 0,
      });
      // On the frames' clock nothing streams between the last painted frame and the click: the click's
      // own frame moves nothing over the line either.
      expect({ step: window.step, clickFramePx: window.clickFramePx }).toEqual({
        step: window.step,
        clickFramePx: Math.min(window.clickFramePx, 0.5),
      });
      expect({ step: window.step, restMs: window.restMs }).toEqual({
        step: window.step,
        restMs: Math.min(window.restMs, REST_MS),
      });
      // An open grows from closed: never drawn whole in its first frame.
      if (window.firstShare !== undefined) expect(window.firstShare).toBeLessThan(0.9);
    }
    // The close 60 ms into the open turns that open back over the travel it drew, not a whole fold
    // from there: at rest sooner than a whole fold replayed (131 ms, the gallery's `stack` look).
    expect(report.find((window) => window.step === "reverse")!.restMs).toBeLessThan(125);
    // A 12 px drag across the line opens nothing and moves nothing.
    expect(report.find((window) => window.step === "drag")?.edgePx).toBe(0);
  });

  /// Each frame's callback holds the main thread this long (harness `?load=`): about 25 frames a
  /// second on the wall clock, as Leo's recording under heavy load drew.
  const LOAD_MS = 30;

  test("under heavy load the line holds, the rows under ride its foot, and nothing turns back", async () => {
    const out = await samples(`&load=${LOAD_MS}`, true);
    if (process.env.CMUX_TOOL_TOGGLE_DUMP)
      await Bun.write(`${process.env.CMUX_TOOL_TOGGLE_DUMP}-load.json`, JSON.stringify(out));
    const report = toggleReport(out, STEPS);
    for (const window of report) console.log(`tool-toggle load ${JSON.stringify(window)}`);
    expect(report.map((window) => [window.step, window.open])).toEqual([
      ["open", true],
      ["close", false],
      ["open-again", true],
      ["reverse", false],
      ["drag", false],
    ]);
    for (const window of report) {
      const got = { step: window.step, anchorPx: window.anchorPx, tearPx: window.tearPx, reversals: window.reversals };
      expect(got).toEqual({
        step: window.step,
        anchorPx: Math.min(window.anchorPx, 0.5),
        tearPx: Math.min(window.tearPx, 0.5),
        reversals: 0,
      });
    }
  });

  // The gallery's looks on the same page (CMUX_TOOL_TOGGLE_LOOKS=settle,stack,quick,jump): each click's
  // window per look, for the PR's table.
  test.skipIf(!process.env.CMUX_TOOL_TOGGLE_LOOKS)("every fold look (CMUX_TOOL_TOGGLE_LOOKS)", async () => {
    for (const look of (process.env.CMUX_TOOL_TOGGLE_LOOKS ?? "").split(",").filter(Boolean)) {
      const report = toggleReport(await samples(`&foldLook=${look}`), STEPS);
      console.log(`tool-toggle look ${look}: ${JSON.stringify(report)}`);
    }
  });
});
