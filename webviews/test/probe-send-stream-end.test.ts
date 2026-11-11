// cmux-web-test-timeout: 600
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

await requireBrowserLane("probe-send-stream-end.test.ts", async () => {
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
      cacheDir: path.join(webviews, "node_modules/.vite-probe-send-stream-end"),
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

  // PROBE (TIP REDS 4, never lands): what moves in the frames of the phase "end" of the scripted
  // "tools" turn, with the shipped arms and with each arm that changed its default on 2026-11-11.
  const LINE_PX = 22.75;
  const MAX_TRAIL_PX = 2 * LINE_PX;
  const ARMS: [string, string][] = [
    ["shipped", ""],
    ["live-turn-work=runs", "arms=live-turn-work:runs"],
    ["turn-fold-replies=groups", "arms=turn-fold-replies:groups"],
    ["composer-dock-motion=push", "arms=composer-dock-motion:push"],
    ["all-three-old", "arms=live-turn-work:runs,turn-fold-replies:groups,composer-dock-motion:push"],
  ];
  const r1 = (value: number) => Math.round(value * 10) / 10;
  test.each(ARMS)("probe %s: the frames of the phase end of the tools turn", async (name, arms) => {
    // The same page as the red test (no row samples), for the number the red test reads.
    const plain = await measure(arms, "tools");
    console.log(
      `PROBE-END ${name} plain: jumpPx.max ${plain.jumpPx.max} end ${JSON.stringify(plain.byPhase.end)} segment ${JSON.stringify(plain.byPhase.segment)}`,
    );
    // Again with every mounted row sampled.
    const { port } = vite!.httpServer!.address() as { port: number };
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?clock=frames&rows=1${arms ? `&${arms}` : ""}`, {
      clock: "frames",
    });
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText("History answer 6.").waitFor();
      frames.start();
      const samples = (await frames.page.evaluate(() =>
        (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
          scenario: "tools",
        }),
      )) as Sample[];
      await frames.stop();
      const first = samples.findIndex((sample) => sample.phase === "end");
      console.log(`PROBE-END ${name} rows: ${samples.length} samples, first end sample ${first}`);
      const from = Math.max(0, first - 3);
      const to = Math.min(samples.length, first + 45);
      let last = "";
      for (let index = from; index < to; index += 1) {
        const sample = samples[index]!;
        const rows = (sample.rows ?? [])
          .filter((row) => row.inView)
          .map(
            (row) =>
              `${row.id.slice(0, 22)}@${r1(row.top)}h${r1(row.height)}o${r1(row.opacity)}${row.moving ? "m" : ""}`,
          )
          .join(" ");
        const line = `top ${r1(sample.top)} lag ${r1(sample.lag)} scrollTop ${r1(sample.scrollTop)} fromEnd ${r1(sample.fromEnd)} tail ${r1(sample.tail)} anim ${sample.animations} | ${rows}`;
        // A frame that draws the same as the one before prints one short line.
        console.log(`PROBE-END ${name} f${index} ${sample.phase} t${r1(sample.t)} ${line === last ? "=" : line}`);
        last = line;
      }
    } finally {
      await frames.close();
    }
    expect(MAX_TRAIL_PX).toBeGreaterThan(0);
  });
});
