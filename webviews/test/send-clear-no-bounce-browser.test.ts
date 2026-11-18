// l10n-allow-file: the gallery fixtures supply the transcript's messages.
// Sending a draft taller than one line moves the transcript one way. The composer clears to one
// line and the prompt's rows come in, and the rows rise with them. Before, the rows were also
// drawn down by the two lines the cleared card gave back, in another frame than the prompt's rise,
// so they dropped 46 px and rose 175 px (or rose and dropped back). The frame judge named that
// bounce in every state whose play sends a prompt (#46151, `follow reversed`).
// From the send until the reply's last line, a followed transcript only rises: no frame draws its
// rows down. Each case records every in-view row's top after every painted frame of the stage's play.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = Record<string, number>;

await requireBrowserLane("send-clear-no-bounce-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-clear-no-bounce-browser: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.send-stream-motion", { browser, params: { variant: "send-stream" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Every in-view transcript row's top (by row id), each frame from the stage's load to its play's end. */
  async function playFrames(variant: string, width: number): Promise<Frame[]> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 640 } });
    // Read after each frame paints (paintedFrames.ts): what the reader saw, the observers run.
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      const w = window as unknown as { cmuxGalleryLoadReport?: unknown; sendFrames: Frame[] };
      w.sendFrames = [];
      window.cmuxAfterPaint(() => {
        if (!w.cmuxGalleryLoadReport) return;
        const frame: Frame = {};
        for (const row of document.querySelectorAll<HTMLElement>("[data-row-id]")) {
          const box = row.getBoundingClientRect();
          if (box.height > 0 && box.bottom > 0 && box.top < innerHeight) frame[row.dataset.rowId!] = box.top;
        }
        w.sendFrames.push(frame);
      });
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.send-stream-motion", { variant, frame: "component", width })}`,
    );
    await page.waitForFunction(
      () => Boolean((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      undefined,
      { timeout: 180_000 },
    );
    const frames = (await page.evaluate(() => (window as unknown as { sendFrames: Frame[] }).sendFrames)) as Frame[];
    await page.close();
    return frames;
  }

  /** The frames whose rows were drawn down: "frame N: row +px" for each row that moved down. */
  function drawnDown(frames: Frame[]): string[] {
    const down: string[] = [];
    for (let index = 1; index < frames.length; index++) {
      for (const [id, top] of Object.entries(frames[index]!)) {
        const was = frames[index - 1]![id];
        if (was !== undefined && top - was > 0.5)
          down.push(`frame ${index}: ${id} +${Math.round((top - was) * 10) / 10}`);
      }
    }
    return down;
  }

  // Whether the bounce's two passes land in one painted frame or two depends on when the observers
  // run, so each width plays three times: on base one play in two or three painted the drop.
  for (const width of [760, 420])
    test(`at ${width} px: sending a three-line draft never draws the rows down`, async () => {
      const down: string[] = [];
      for (let play = 1; play <= 3; play++) {
        const frames = await playFrames("send-stream", width);
        expect(frames.length).toBeGreaterThan(30);
        down.push(
          ...drawnDown(frames)
            .slice(0, 3)
            .map((move) => `play ${play}: ${move}`),
        );
      }
      expect(down).toEqual([]);
    });
});
