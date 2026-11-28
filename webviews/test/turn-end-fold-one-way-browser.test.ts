// l10n-allow-file: the gallery fixtures supply the transcript's messages.
// A followed turn's end moves the rows one way. The turn-end fold slides the rows down to meet the
// folded line (turnEndFold.ts), and the reply's last held-back lines still reveal after the turn
// ends, raising the rows on the follow chase (VirtualTranscript's drain). Before, the two played as
// two opposite moves: the rows came down with the fold and went back up with the reply's last
// lines, a bounce the frame judge named in agent-pane.streaming-follow-motion#eased-follow
// (`follow reversed`: +11.7 px, then -8.4 px).
// From the frame the running turn's line goes until the play's end, no painted frame turns the
// followed rows' movement round. Each case records every in-view row's top after every painted
// frame of the stage's play.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = { live: boolean; rows: Record<string, number> };

await requireBrowserLane("turn-end-fold-one-way-browser.test.ts", async () => {
  /** A follow that turns round within this many frames of the last one bounced (followJudge.ts). */
  const REVERSE_FRAMES = 3;
  /** Moves under this are not moves (shift.ts MOVE_SLACK). */
  const SLACK = 0.5;
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("turn-end-fold-one-way-browser: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.streaming-follow-motion";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "eased-follow" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Every in-view transcript row's top (by row id), each painted frame from the stage's load to its
   *  play's end, and whether the running turn's line was still drawn. */
  async function playFrames(variant: string, width: number): Promise<Frame[]> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 560 } });
    // Read after each frame paints (paintedFrames.ts): what the reader saw, the observers run.
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      const w = window as unknown as { cmuxGalleryLoadReport?: unknown; foldFrames: Frame[] };
      w.foldFrames = [];
      window.cmuxAfterPaint(() => {
        if (!w.cmuxGalleryLoadReport) return;
        const rows: Record<string, number> = {};
        for (const row of document.querySelectorAll<HTMLElement>(".acpmux-thread > [data-row-id]")) {
          const box = row.getBoundingClientRect();
          if (box.height > 0 && box.bottom > 0 && box.top < innerHeight) rows[row.dataset.rowId!] = box.top;
        }
        w.foldFrames.push({ live: Boolean(document.querySelector('[data-row-id="thinking-live"]')), rows });
      });
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, frame: "component", width, height: 560 })}`,
    );
    await page.waitForFunction(
      () => Boolean((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      undefined,
      { timeout: 180_000 },
    );
    const frames = (await page.evaluate(() => (window as unknown as { foldFrames: Frame[] }).foldFrames)) as Frame[];
    await page.close();
    return frames;
  }

  /** The frames, from the turn's end on, whose rows' shared move turned round within REVERSE_FRAMES
   *  of the last move: "frame N: row +a then -b". The shared move is the one most rows made. */
  function turnedRound(frames: Frame[]): string[] {
    const ended = frames.findIndex((frame, index) => index > 0 && frames[index - 1]!.live && !frame.live);
    if (ended < 0) return ["the running turn's line never went"];
    const turned: string[] = [];
    let last = { frame: -REVERSE_FRAMES - 1, dy: 0, id: "" };
    for (let index = Math.max(1, ended - REVERSE_FRAMES); index < frames.length; index++) {
      const dys: [string, number][] = [];
      for (const [id, top] of Object.entries(frames[index]!.rows)) {
        const was = frames[index - 1]!.rows[id];
        if (was !== undefined) dys.push([id, top - was]);
      }
      // The move most rows share (ties: the smaller), as the frame judge's follow.
      let shared: [string, number] | undefined;
      let count = 0;
      for (const [id, dy] of dys) {
        const with_ = dys.filter(([, other]) => Math.abs(other - dy) <= SLACK).length;
        if (with_ > count || (with_ === count && shared && Math.abs(dy) < Math.abs(shared[1]))) {
          shared = [id, dy];
          count = with_;
        }
      }
      if (!shared || Math.abs(shared[1]) <= SLACK) continue;
      const [id, dy] = shared;
      if (
        index >= ended &&
        index - last.frame <= REVERSE_FRAMES &&
        Math.abs(last.dy) > SLACK &&
        Math.sign(dy) !== Math.sign(last.dy)
      )
        turned.push(
          `frame ${index - ended} after the end: ${last.id} ${last.dy > 0 ? "+" : ""}${Math.round(last.dy * 10) / 10}` +
            ` then ${id} ${dy > 0 ? "+" : ""}${Math.round(dy * 10) / 10}`,
        );
      last = { frame: index, dy, id };
    }
    return turned;
  }

  // Whether the fold's slide and the reply's last lines land in the same painted frames depends on
  // when the stream's timer fires against the frames, so the turn ends four times: on base two plays
  // in three drew the rows down and back up.
  test("at 760 px: the followed turn's end never turns the rows' movement round", async () => {
    const turned: string[] = [];
    for (let play = 1; play <= 4; play++) {
      const frames = await playFrames("eased-follow", 760);
      expect(frames.length).toBeGreaterThan(30);
      turned.push(...turnedRound(frames).map((move) => `play ${play}: ${move}`));
    }
    expect(turned).toEqual([]);
  });
});
