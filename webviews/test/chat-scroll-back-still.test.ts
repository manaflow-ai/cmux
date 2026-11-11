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
  /// How long after the scroll back down a held follow motion played out on base (its spring home).
  const SLIDE_MS = 250;
  /// From here on the wheel's own motion has ended; the fold comes once input has been quiet for
  /// USER_SCROLL_INTENT_MS (1 s).
  const QUIET_FROM_MS = 900;

  // 60 px: the rows under the landing call stay in view while the reader reads. 600 px: they leave it,
  // so their held glides end unseen (tailGlide.ts dropUnseen) and nothing of them plays on the return.
  test.each([60, 600])(
    "wheeling up %i px and back down to the latest row after reading moves no row the reader sees",
    async (px) => {
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
          ({ backMs, px }) =>
            (window as unknown as { __sendStream: { run(options: object): Promise<Sample[]> } }).__sendStream.run({
              scenario: "arrive-tool",
              settleMs: backMs + 600,
              wheel: { at: "land", afterMs: 16, px, backMs },
            }),
          { backMs: READ_MS, px },
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
      // While the reader reads, across their input going quiet (USER_SCROLL_INTENT_MS), every row holds
      // its place: its screen top less the thread's translate, plus the offset, never changes. A held
      // chase folded into the offset keeps that; a row's own glide cut short would not.
      const reading = out.filter((sample) => sample.t > wheeled! + 2 * FRAME_MS && sample.t < back!);
      expect(reading.some((sample) => sample.t > wheeled! + 1100)).toBe(true);
      // In a frame whose offset moved around the quiet point (the fold; the wheel's own motion has
      // ended by then), the rows also hold their places on screen: the layout check above can't see
      // a fold that moves offset and translate apart.
      let drift = 0;
      let drifted: string | undefined;
      let folded = 0;
      let jump = 0;
      let jumped: string | undefined;
      for (let index = 1; index < reading.length; index += 1) {
        const was = reading[index - 1]!;
        const now = reading[index]!;
        const before = new Map((was.rows ?? []).map((row) => [row.id, row]));
        const offsetMoved = now.t > wheeled! + QUIET_FROM_MS && Math.abs(now.scrollTop - was.scrollTop) > 0.5;
        if (offsetMoved) folded += 1;
        for (const row of now.rows ?? []) {
          const prior = before.get(row.id);
          // What the reader sees: a row in the view, over the composer (a row under the glass composer
          // is the reply's live end, which streams on under it).
          if (!prior || !row.inView || row.top >= (now.composer ?? Number.POSITIVE_INFINITY)) continue;
          const shift = Math.abs(row.top + now.scrollTop - now.lag - (prior.top + was.scrollTop - was.lag));
          if (shift > drift) {
            drift = shift;
            drifted = row.id;
          }
          const onScreen = offsetMoved ? Math.abs(row.top - prior.top) : 0;
          if (onScreen > jump) {
            jump = onScreen;
            jumped = row.id;
          }
        }
      }
      console.log(
        `chat-scroll-back-still: while reading, rows ${drift.toFixed(1)} px (${drifted ?? "none"}); ` +
          `${folded} offset moves, rows ${jump.toFixed(1)} px on screen (${jumped ?? "none"})`,
      );
      expect({ drift: Math.round(drift * 10) / 10, drifted }).toEqual({
        drift: Math.min(Math.round(drift * 10) / 10, 0.5),
        drifted,
      });
      expect({ jump: Math.round(jump * 10) / 10, jumped }).toEqual({
        jump: Math.min(Math.round(jump * 10) / 10, 0.5),
        jumped,
      });
      // Every frame after the one the reader's scroll back down drew in, for as long as a held follow
      // motion took to play out (about a dozen frames on base): the thread is drawn at its layout, so
      // nothing slides home under the view.
      const after = out.filter((sample) => sample.t > back! + FRAME_MS && sample.t <= back! + SLIDE_MS);
      expect(after.length).toBeGreaterThan(20);
      let most = 0;
      let moved: string | undefined;
      for (let index = 1; index < after.length; index += 1) {
        const before = new Map((after[index - 1]!.rows ?? []).map((row) => [row.id, row]));
        for (const row of after[index]!.rows ?? []) {
          const was = before.get(row.id);
          // On screen, over the composer: what the reader sees.
          if (!was || !row.inView || row.top >= (after[index]!.composer ?? Number.POSITIVE_INFINITY)) continue;
          const shift = Math.abs(row.top - was.top);
          if (shift > most) {
            most = shift;
            moved = row.id;
          }
        }
      }
      const lag = Math.max(...after.map((sample) => Math.abs(sample.lag)));
      console.log(
        `chat-scroll-back-still ${px}: lag ${lag.toFixed(1)} px, rows ${most.toFixed(1)} px (${moved ?? "none"})`,
      );
      expect(Math.round(lag * 10) / 10).toBeLessThanOrEqual(0.5);
      expect({ most: Math.round(most * 10) / 10, moved }).toEqual({
        most: Math.min(Math.round(most * 10) / 10, 0.5),
        moved,
      });
    },
  );
});
