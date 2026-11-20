// l10n-allow-file: the gallery fixtures supply the transcript's messages.
// A prompt that comes in while the reader follows (its row and the running turn's live line, the
// composer's card clearing with it) moves the transcript one way, in every chasing arm of the follow
// motion (followMotion.experiment.ts). In the `spring`, `chunk` and `linear` arms the prompt's rows
// moved up at once past a line under the composer (the rule for a reply's new text), and the room
// the cleared card gave back a pass later was chased down on its own: the rows rose 149 px in one
// frame and dropped 10 to 32 px back over the next ones (the frame judge's `follow reversed` at the
// click of agent-pane.send-stream-motion#tools-turn and #steer-mid-stream).
// From the click until the reply's first words, no frame draws a followed row down. Each case
// records every in-view row's top after every painted frame of the stage's play.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = Record<string, number>;

await requireBrowserLane("follow-arm-prompt-rise-browser.test.ts", async () => {
  /// The reply's first row in the scripted turns (scriptedTurn.ts ANSWER_ID): the prompt step ends there.
  const ANSWER = "live-answer";
  setDefaultTimeout(600_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("follow-arm-prompt-rise-browser: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.send-stream-motion", { browser, params: { variant: "tools-turn" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Every in-view transcript row's top (by row id), each painted frame from the stage's load until
   *  the reply's first row is drawn. */
  async function promptFrames(variant: string, arm: string): Promise<Frame[]> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 760, height: 600 } });
    // Read after each frame paints (paintedFrames.ts): what the reader saw, the observers run.
    await installPaintedFrames(page);
    await page.addInitScript((answer: string) => {
      const w = window as unknown as { clicked?: boolean; promptFrames: Frame[]; answered?: boolean };
      w.promptFrames = [];
      const rows = () => {
        const frame: Frame = {};
        for (const row of document.querySelectorAll<HTMLElement>("[data-row-id]")) {
          const box = row.getBoundingClientRect();
          if (box.height > 0 && box.bottom > 0 && box.top < innerHeight) frame[row.dataset.rowId!] = box.top;
        }
        return frame;
      };
      // From the rows as painted when the play's click comes (the stage plays as soon as it loads):
      // the click's own commit lands before the next paint.
      addEventListener(
        "click",
        (event) => {
          if (!(event.target as Element | null)?.closest?.("[data-testid=send-stream-play]")) return;
          w.clicked = true;
          w.promptFrames.push(rows());
        },
        true,
      );
      window.cmuxAfterPaint(() => {
        if (!w.clicked || w.answered) return;
        const frame = rows();
        if (frame[answer] !== undefined) w.answered = true;
        else w.promptFrames.push(frame);
      });
    }, ANSWER);
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.send-stream-motion", {
        variant,
        frame: "component",
        width: 760,
        height: 600,
        exp: "follow-motion",
        arm,
      })}`,
    );
    await page.waitForFunction(() => Boolean((window as unknown as { answered?: boolean }).answered), undefined, {
      timeout: 180_000,
    });
    const frames = (await page.evaluate(
      () => (window as unknown as { promptFrames: Frame[] }).promptFrames,
    )) as Frame[];
    await page.close();
    return frames;
  }

  /** "frame N: row +px" for each row a frame drew down, and whether any frame drew the rows up. */
  function moves(frames: Frame[]): { down: string[]; rose: boolean } {
    const down: string[] = [];
    let rose = false;
    for (let index = 1; index < frames.length; index++) {
      for (const [id, top] of Object.entries(frames[index]!)) {
        const was = frames[index - 1]![id];
        if (was === undefined) continue;
        if (top - was > 0.5) down.push(`frame ${index}: ${id} +${Math.round((top - was) * 10) / 10}`);
        if (was - top > 0.5) rose = true;
      }
    }
    return { down, rose };
  }

  // Whether the prompt's rows and the card's room land in one pass or two depends on when the
  // observers run, so each case plays twice.
  for (const variant of ["tools-turn", "steer-mid-stream"])
    for (const arm of ["spring", "chunk", "linear"])
      test(`${variant}, ${arm} arm: a prompt that comes in never draws the rows down`, async () => {
        const down: string[] = [];
        for (let play = 1; play <= 2; play++) {
          const frames = await promptFrames(variant, arm);
          const seen = moves(frames);
          // The prompt's rows came in and raised the rows above (the play really ran).
          expect({ frames: frames.length, rose: seen.rose }).toEqual({ frames: frames.length, rose: true });
          down.push(...seen.down.slice(0, 3).map((move) => `play ${play}: ${move}`));
        }
        expect(down).toEqual([]);
      });
});
