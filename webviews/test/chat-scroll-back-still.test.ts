// cmux-web-test-timeout: 240
// Leo, 2026-11-09: "when i scroll down now there's a little readjustment sometimes that shold never
// happen some of our recent animations are too much we need to slim down".
//
// The reader wheels up while a running turn's follow motion is in flight (a call landing: the chase
// draws the thread back and brings it home, the rows under the call glide), reads, and wheels back
// down to the latest row. Their input held that motion where it was drawn (row-arrival-settle), and
// it played on the moment the view was followed again: the rows moved under the view the reader had
// just scrolled to. Once they are at the latest row and the page draws nothing new, nothing moves.
//
// The page is send-stream-motion's (browser/send-stream-motion.harness.tsx) on the frames' own clock.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Sample } from "./browser/send-stream-motion.harness";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { FRAME_MS } from "./support/rowArrivalReport";

await requireBrowserLane("chat-scroll-back-still.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(120_000);
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn("chat-scroll-back-still: skipping, this Chrome draws no frames on the test's clock");
    describe.skip("scroll back down", () => test("no chrome-headless-shell", () => {}));
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

  const HISTORY = 17;
  /// The reader reads for longer than their input's hold (userScroll.ts USER_SCROLL_INTENT_MS).
  const READ_MS = 1500;

  test("wheeling back down to the latest row after reading moves no row the reader sees", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?clock=frames&rows=1&history=${HISTORY}`, {
      clock: "frames",
    });
    let out: Sample[];
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText(`History answer ${HISTORY - 1}.`).waitFor();
      frames.start();
      out = (await frames.page.evaluate(
        (backMs) =>
          (window as unknown as { __sendStream: { run(options: object): Promise<Sample[]> } }).__sendStream.run({
            scenario: "arrive-tool",
            settleMs: backMs + 600,
            wheel: { at: "land", afterMs: 16, px: 60, backMs },
          }),
        READ_MS,
      )) as Sample[];
      await frames.stop();
    } finally {
      await frames.close();
    }
    const wheeled = out.find((sample) => sample.wheeledAt !== undefined)?.wheeledAt;
    const back = out.find((sample) => sample.backAt !== undefined)?.backAt;
    expect(wheeled).toBeDefined();
    expect(back).toBeDefined();
    // The wheel came while the follow motion was in flight: the thread was drawn away from its layout.
    const held = out.filter((sample) => sample.t >= wheeled! && sample.t < wheeled! + 4 * FRAME_MS);
    expect(Math.max(...held.map((sample) => Math.abs(sample.lag)))).toBeGreaterThan(1);
    // Every frame after the one the reader's scroll back down drew in.
    const after = out.filter((sample) => sample.t > back! + FRAME_MS);
    expect(after.length).toBeGreaterThan(20);
    let most = 0;
    let moved: string | undefined;
    for (let index = 1; index < after.length; index += 1) {
      const before = new Map((after[index - 1]!.rows ?? []).map((row) => [row.id, row]));
      for (const row of after[index]!.rows ?? []) {
        const was = before.get(row.id);
        if (!was) continue;
        const shift = Math.abs(row.top - was.top);
        if (shift > most) {
          most = shift;
          moved = row.id;
        }
      }
    }
    const lag = after
      .map((sample) => Math.round(sample.lag * 10) / 10)
      .filter((value, at, all) => value !== all[at - 1]);
    console.log(
      `chat-scroll-back-still: most ${most.toFixed(1)} px (${moved ?? "none"}); fromEnd at back ${after[0]!.fromEnd.toFixed(1)}, at end ${after.at(-1)!.fromEnd.toFixed(1)}; lag ${lag.slice(0, 12).join(",")}`,
    );
    expect({ most: Math.round(most * 10) / 10, moved }).toEqual({
      most: Math.min(Math.round(most * 10) / 10, 0.5),
      moved,
    });
  });
});
