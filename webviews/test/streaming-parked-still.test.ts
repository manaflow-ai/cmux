// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-10-27: "im still getting flickering rerenderings on certain weird scroll things when
// you're streaming text and im on some in between zone". A reader partway up a streaming reply
// (neither at its latest line nor far away: the reply still on screen) sees nothing but their own
// scroll: no row or block of the reply moves on its own, none still in view leaves the DOM for a
// frame, and the offset never changes without input.
//
// The page is the streaming-text harness (browser/streaming-text.harness.tsx): the real
// VirtualTranscript over a chat's history with the bottom stack over its foot, streaming the
// 5,000-character Markdown reply at Claude's cadence. Mid-stream the test either parks the reader a
// distance up with one real wheel and samples every painted frame until the reply has drained, or
// wanders up from the latest line and back down to it in a trackpad's small steps, twice, sampling
// as it goes. Each frame records the screen top of every row and of every block of the reply in view.
// The view's scroll between two frames is how far the picture moved, read off the items themselves
// (their common move): the offset, the follow motion's translate and the thread's scroll origin are
// the app's own split of one picture, and a reader sees only the picture. Each item still drawn must
// have moved by exactly that scroll; an item gone while the scroll alone would leave it in view is a
// blank flash. The picture moves only while the reader's own scroll is under way: from the frame their
// first wheel event acted on until that scroll has ended. A notch is the reader's distance, eased by
// the app over a motion step (wheelGlide.ts); it ends when the app says so (WHEEL_GLIDE_END_EVENT, on
// its last step or when anything cancels it), not at `scrollend`, which Chromium fires after each of
// the glide's writes. A scroll the browser runs itself (a precise wheel, WebKit's here) ends at its
// `scrollend`. Then the view must hold for PARKED_FRAMES painted frames at least, its offset still,
// so a scroll still under way at the last frame read can never pass for one that came to rest
// (review of #40918 F1: 100 frames still moving were read as settled). The test reads all of that
// from the order of events (wheels and glides counted), never from a clock, so a starved runner that
// stretches frames, skips one mid-scroll, or delivers the wheel late, changes nothing it measures.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { PARKED, parkedAfterScroll, stillness, type Sample } from "./support/parkedStill";
import { WHEEL_GLIDE_END_EVENT, WHEEL_GLIDE_START_EVENT } from "../src/agent-session/acpmux/wheelGlide";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Probe = Window & {
  __still: {
    samples: Sample[];
    sampling: boolean;
    done: boolean;
    wheels: number;
    ended: boolean;
    glides: number;
    gliding: boolean;
    run?: Promise<unknown>;
  };
  __streamingText: { run(options: { cadence: string }): Promise<unknown> };
};
await requireBrowserLane("streaming-parked-still.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][])
    if (await probeEngineOrSkip("streaming-parked-still.test.ts", engine[0], engine[1])) engines.push(engine);
  if (engines.length === 0) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/streaming-text.html");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /// The harness page streaming its reply, with a frame sampler that runs until the page closes
  /// (`done` ends its frame loop), and the pointer over the transcript once the reply fills a screen.
  async function streaming(name: string): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/streaming-text.html`);
    await page.waitForFunction(() => "__streamingText" in window);
    await page.getByText("History answer 6.").waitFor();
    // fixed-wait: nothing marks the page's start-up as done (as streaming-text-frames.test.ts)
    await page.waitForTimeout(500);
    await page.evaluate(
      ({ START, END }) => {
        const w = window as unknown as Probe;
        w.__still = { samples: [], sampling: false, done: false, wheels: 0, ended: false, glides: 0, gliding: false };
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        // Each wheel event, before the page's own handlers see it (and after the read of the frame
        // painted before it, which paintedFrames.ts runs from its window capture first).
        const wheel = () => {
          w.__still.wheels += 1;
          w.__still.ended = false;
        };
        // The scroll the browser eased in for them has ended (or an offset the page wrote has landed).
        const ended = () => (w.__still.ended = true);
        // The app's easing of a notch (wheelGlide.ts): started in the wheel's own handler, ended on its
        // last step or when anything cancels it. Until it ends, the reader's scroll is under way.
        const glideStart = () => {
          w.__still.glides += 1;
          w.__still.gliding = true;
        };
        const glideEnd = () => (w.__still.gliding = false);
        scroller.addEventListener("wheel", wheel, { capture: true, passive: true });
        scroller.addEventListener("scrollend", ended, { passive: true });
        scroller.addEventListener(START, glideStart);
        scroller.addEventListener(END, glideEnd);
        // Read after each frame paints (paintedFrames.ts), until the page is done.
        window.cmuxAfterPaint((t) => {
          if (w.__still.done) {
            scroller.removeEventListener("wheel", wheel, { capture: true });
            scroller.removeEventListener("scrollend", ended);
            scroller.removeEventListener(START, glideStart);
            scroller.removeEventListener(END, glideEnd);
            return false;
          }
          if (w.__still.sampling) {
            const view = scroller.getBoundingClientRect();
            const items: Record<string, number> = {};
            const inView = (rect: DOMRect) => rect.height > 0 && rect.bottom > view.top && rect.top < view.bottom;
            // A new block or row rises 4px as it fades in (conversation.css `cv-enter`): designed
            // motion, so an item counts once its own animations have finished.
            const entering = (node: Element) =>
              node.getAnimations().some((animation) => animation.playState === "running");
            for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
              const rect = row.getBoundingClientRect();
              if (inView(rect) && !entering(row)) items[`row:${row.dataset.rowId}`] = rect.top;
            }
            const reply = scroller.querySelector<HTMLElement>('.acpmux-row[data-row-id="live-answer"] .cv-md');
            if (reply)
              [...reply.children].forEach((child, index) => {
                const rect = child.getBoundingClientRect();
                if (inView(rect) && !entering(child)) items[`block:${index}:${child.tagName}`] = rect.top;
              });
            w.__still.samples.push({
              t,
              top: scroller.scrollTop,
              lag:
                Number.parseFloat(
                  getComputedStyle(scroller.querySelector<HTMLElement>(".acpmux-thread")!).translate.split(" ")[1] ??
                    "",
                ) || 0,
              fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              wheels: w.__still.wheels,
              ended: w.__still.ended,
              glides: w.__still.glides,
              gliding: w.__still.gliding,
              view: [view.top, view.bottom],
              items,
            });
          }
          return true;
        });
        w.__still.run = w.__streamingText.run({ cadence: "claude" });
      },
      { START: WHEEL_GLIDE_START_EVENT, END: WHEEL_GLIDE_END_EVENT },
    );
    await page.waitForFunction(
      () => (document.querySelector('.acpmux-row[data-row-id="live-answer"] .cv-md')?.textContent?.length ?? 0) > 1_200,
      undefined,
      { timeout: 30_000 },
    );
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 3);
    return page;
  }

  /// Samples the frames from now until the reply has drained, then closes the page.
  async function sampleToEnd(page: Page) {
    await page.evaluate(() => ((window as unknown as Probe).__still.sampling = true));
    await page.evaluate(() => (window as unknown as Probe).__still.run);
    const samples = await page.evaluate(() => {
      const w = window as unknown as Probe;
      w.__still.done = true;
      return w.__still.samples;
    });
    await page.close();
    return samples;
  }

  test.each(engines.flatMap(([name]) => [60, 120, 480].map((px) => `${name} ${px}`)))(
    "%s px up: a parked reader's view holds still while the reply streams below",
    async (label) => {
      const [name, px] = label.split(" ") as [string, string];
      const page = await streaming(name);
      await page.evaluate(() => ((window as unknown as Probe).__still.sampling = true));
      await page.mouse.wheel(0, -Number(px));
      // With CMUX_MOTION_STILLS=<dir>: whole-window stills of the parked view as the reply streams on
      // below it, for review (#41454). They read the same picture each time: the view holds.
      const stills = process.env.CMUX_MOTION_STILLS;
      if (stills && px === "120") {
        const dir = path.join(stills, "parked-reader", name);
        mkdirSync(dir, { recursive: true });
        for (const at of [1, 2, 3]) {
          // fixed-wait: the reply streams on between stills.
          await page.waitForTimeout(600);
          await page.screenshot({ path: path.join(dir, `${at}-parked-${at * 600}ms-after-wheel.png`) });
        }
      }
      const report = stillness(await sampleToEnd(page));
      console.log(`streaming-parked-still ${label}: ${JSON.stringify(report)}`);
      // The reply was on screen, and the reader stayed off its latest line (past the follow
      // deadband, App.tsx FOLLOW_BOTTOM_DEADBAND_PX); how far one wheel event travels is the engine's.
      expect(report.blockFrames).toBeGreaterThan(30);
      expect(report.offsetMoves).toBeGreaterThan(0);
      expect(report.fromEnd).toBeGreaterThan(4);
      // The page saw the wheel and its scroll came to rest: what follows is the parked view.
      expect(report.wheels).toBe(1);
      expect(parkedAfterScroll(report)).toEqual(PARKED);
      expect({ unprompted: report.unprompted, events: report.first }).toEqual({ unprompted: [], events: [] });
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: scrolling up through the in-between zone and back while the reply streams moves nothing but the scroll",
    async (name) => {
      const page = await streaming(name);
      await page.evaluate(() => ((window as unknown as Probe).__still.sampling = true));
      // Up, down to the latest line, up, down, and up again: the reader ends parked in the zone.
      for (const direction of [-1, 1, -1, 1, -1])
        for (let index = 0; index < 14; index += 1) {
          await page.mouse.wheel(0, direction * 30);
          // fixed-wait: the spacing of a trackpad's wheel events is the input under test
          await page.waitForTimeout(32);
        }
      const report = stillness(await sampleToEnd(page));
      console.log(`streaming-parked-still ${name} wander: ${JSON.stringify(report)}`);
      expect(report.blockFrames).toBeGreaterThan(30);
      expect(report.offsetMoves).toBeGreaterThan(10);
      expect(report.fromEnd).toBeGreaterThan(4);
      expect(report.wheels).toBeGreaterThan(0);
      expect(parkedAfterScroll(report)).toEqual(PARKED);
      // While the wheel turns, the view follows it and, at the latest line, the reply; once the
      // reader's last scroll has settled, parked again, nothing moves it.
      expect({ late: report.late, events: report.first }).toEqual({ late: [], events: [] });
    },
  );
});
