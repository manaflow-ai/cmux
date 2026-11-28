// The live line's words handing over to a tool call, held to its bounds frame by frame (Leo,
// 2026-11-21: "the animation for the Thinking swapping to tool calls also probably needs to be
// smoothed out"). On the scripted `arrive-tool` turn (browser/send-stream-motion.harness.tsx) the call
// ends: its row arrives a line over the live line while the line's words (the call) hand over to the
// next. Every 120 Hz frame from the frame before to 400 ms after:
// - the leaving words and the arriving row are never drawn at once (the call's name twice; the roll
//   before this, `?liveSwap=roll`, drew it 8 frames), nor cross its words' box;
// - nothing on the live line moves more than 0.6 line in one frame (turn-transition-jumps.test.ts's
//   LINE_PX), and the hand-over rests within 200 ms.
// CMUX_SWAP_LOOK=roll runs it on another look (the roll fails the first bound: red before green).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import {
  arrivingRows,
  drawnTwice,
  movedPx,
  overlapPx,
  recordSwap,
  SWAP_ARM_QUERY,
  SWAP_PAGE,
  swapFrameGate,
} from "./support/thinkingToolSwap";

await requireBrowserLane("thinking-tool-swap-frames.test.ts", async () => {
  setDefaultTimeout(180_000);
  const LINE_PX = 22.75;
  const MAX_FRAME_PX = 0.6 * LINE_PX;
  const FRAME_MS = 1000 / 120;
  const look = process.env.CMUX_SWAP_LOOK ?? "";
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-thinking-tool-swap"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, SWAP_PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  test(`the live line hands its words to the call without drawing it twice or jumping (${look || "shipped"})`, async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const browser = await chromium.launch({
      headless: true,
      ...(process.env.CMUX_BROWSER_EXECUTABLE && { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }),
    });
    try {
      const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
      await page.addInitScript(swapFrameGate);
      await page.goto(
        `http://127.0.0.1:${port}${SWAP_PAGE}?clock=frames&rows=1${SWAP_ARM_QUERY}${look ? `&liveSwap=${look}` : ""}`,
      );
      const { frames, landed } = await recordSwap(page);
      expect(landed).toBeGreaterThan(0);
      const arriving = arrivingRows(frames, landed);
      // The call's row arrives, and the line's words hand over (the leaving copy is drawn at all).
      expect(arriving.size).toBeGreaterThan(0);
      expect(frames.slice(landed).some((frame) => frame.out)).toBe(true);
      const twice: number[] = [];
      let overlap = 0;
      let moved = 0;
      let rest = 0;
      for (let index = landed; index < frames.length; index += 1) {
        const frame = frames[index]!;
        const before = frames[index - 1]!;
        if (drawnTwice(frame, arriving)) twice.push(index - landed);
        overlap = Math.max(overlap, overlapPx(frame, arriving));
        moved = Math.max(moved, movedPx({ ...before, rows: [] }, { ...frame, rows: [] }));
        const still = (at: typeof frame) =>
          JSON.stringify([at.out, at.now, at.live, at.rows.map((row) => [row.box.top, row.ink])]);
        if (still(frame) !== still(before)) rest = (index - landed + 1) * FRAME_MS;
      }
      expect({ twice, overlap }).toEqual({ twice: [], overlap: 0 });
      expect(moved).toBeLessThanOrEqual(MAX_FRAME_PX);
      expect(rest).toBeLessThanOrEqual(200);
    } finally {
      await browser.close();
    }
  });
});
