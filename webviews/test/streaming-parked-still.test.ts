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
// first wheel event acted on until the first frame the picture holds still after their last one. The
// test reads that from the order of events, never from a clock, so a starved runner that stretches
// frames, or delivers the wheel late, changes nothing it measures.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One painted frame: its time, the offset and how far it rests from the end, the view's edges, how
/// many wheel events the page had seen when it was read, and the screen top of each row and reply
/// block in view.
type Sample = {
  t: number;
  top: number;
  fromEnd: number;
  wheels: number;
  /// The follow motion's translate on the thread, px: rows drawn off their layout by it.
  lag: number;
  view: [number, number];
  items: Record<string, number>;
};
type Probe = Window & {
  __still: { samples: Sample[]; sampling: boolean; done: boolean; wheels: number; run?: Promise<unknown> };
  __streamingText: { run(options: { cadence: string }): Promise<unknown> };
};
/// An item that moved apart from the scroll, or vanished in view, between two painted frames.
type Event = { t: number; key: string; kind: "moved" | "vanished"; px?: number; scrolled: number };

await requireBrowserLane("streaming-parked-still.test.ts", async () => {
  const round = (value: number) => Math.round(value * 100) / 100;

  /// How far the picture scrolled from `before` to `now`, toward the end positive: the move most of
  /// the items drawn in both frames share (the middle one), so one item moving on its own cannot pass
  /// for the scroll. With no item in both, the offset less the follow motion's translate.
  function pictureScroll(before: Sample, now: Sample) {
    const moves = Object.keys(before.items)
      .filter((key) => key in now.items)
      .map((key) => before.items[key]! - now.items[key]!)
      .sort((a, b) => a - b);
    if (moves.length > 0) return moves[Math.floor(moves.length / 2)]!;
    return now.top - before.top - (now.lag - before.lag);
  }

  /// What moved apart from the scroll in `samples`, and how often the picture scrolled.
  function stillness(samples: Sample[]) {
    const events: Event[] = [];
    let offsetMoves = 0;
    /// Scrolls toward the end, or after the reader's scroll has settled: not the reader's.
    const unprompted: { t: number; px: number }[] = [];
    /// Scrolls, either way, after the reader's scroll has settled.
    const late: { t: number; px: number }[] = [];
    let blockFrames = 0;
    const wheels = samples.at(-1)?.wheels ?? 0;
    // The frame the reader's first wheel event acted on: the last one read before the page saw it
    // (paintedFrames.ts runs a painted frame's read before any input event's handlers). Frames before
    // it are of the followed view, the reader's input still on its way to the page.
    const from = Math.max(0, samples.findIndex((sample) => sample.wheels > 0) - 1);
    // The first frame read after the last wheel event: from there, the first frame in which the
    // picture holds still after it has moved is where the reader's scroll has settled.
    const last = samples.findIndex((sample) => sample.wheels === wheels);
    let moved = false;
    let settled: number | undefined;
    const t0 = samples[from]?.t ?? 0;
    for (let index = from + 1; index < samples.length; index += 1) {
      const before = samples[index - 1]!;
      const now = samples[index]!;
      const scrolled = pictureScroll(before, now);
      const t = Math.round(now.t - t0);
      if (Object.keys(now.items).some((key) => key.startsWith("block:"))) blockFrames += 1;
      const moving = Math.abs(scrolled) > 0.5;
      if (settled === undefined && index >= last) {
        if (moving) moved = true;
        else if (moved) settled = index;
      }
      if (moving) {
        offsetMoves += 1;
        const after = settled !== undefined;
        if (after) late.push({ t, px: round(scrolled) });
        if (after || scrolled > 0) unprompted.push({ t, px: round(scrolled) });
      }
      for (const [key, top] of Object.entries(before.items)) {
        const expected = top - scrolled;
        if (!(key in now.items)) {
          if (expected > now.view[0] + 2 && expected < now.view[1] - 2)
            events.push({ t, key, kind: "vanished", scrolled: round(scrolled) });
          continue;
        }
        const px = now.items[key]! - expected;
        if (Math.abs(px) > 0.5) events.push({ t, key, kind: "moved", px: round(px), scrolled: round(scrolled) });
      }
    }
    return {
      frames: samples.length - from,
      blockFrames,
      offsetMoves,
      fromEnd: round(samples.at(-1)?.fromEnd ?? 0),
      wheels,
      settled: settled === undefined ? undefined : Math.round(samples[settled]!.t - t0),
      unprompted: unprompted.slice(0, 16),
      late: late.slice(0, 16),
      events: events.length,
      first: events.slice(0, 16),
    };
  }

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
    await page.evaluate(() => {
      const w = window as unknown as Probe;
      w.__still = { samples: [], sampling: false, done: false, wheels: 0 };
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      // Each wheel event, before the page's own handlers see it (and after the read of the frame
      // painted before it, which paintedFrames.ts runs from its window capture first).
      const wheel = () => (w.__still.wheels += 1);
      scroller.addEventListener("wheel", wheel, { capture: true, passive: true });
      // Read after each frame paints (paintedFrames.ts), until the page is done.
      window.cmuxAfterPaint((t) => {
        if (w.__still.done) {
          scroller.removeEventListener("wheel", wheel, { capture: true });
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
                getComputedStyle(scroller.querySelector<HTMLElement>(".acpmux-thread")!).translate.split(" ")[1] ?? "",
              ) || 0,
            fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
            wheels: w.__still.wheels,
            view: [view.top, view.bottom],
            items,
          });
        }
        return true;
      });
      w.__still.run = w.__streamingText.run({ cadence: "claude" });
    });
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
      const report = stillness(await sampleToEnd(page));
      console.log(`streaming-parked-still ${label}: ${JSON.stringify(report)}`);
      // The reply was on screen, and the reader stayed off its latest line (past the follow
      // deadband, App.tsx FOLLOW_BOTTOM_DEADBAND_PX); how far one wheel event travels is the engine's.
      expect(report.blockFrames).toBeGreaterThan(30);
      expect(report.offsetMoves).toBeGreaterThan(0);
      expect(report.fromEnd).toBeGreaterThan(4);
      // The page saw the wheel and its scroll came to rest: what follows is the parked view.
      expect(report.wheels).toBe(1);
      expect(report.settled).toBeNumber();
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
      expect(report.settled).toBeNumber();
      // While the wheel turns, the view follows it and, at the latest line, the reply; once the
      // reader's last scroll has settled, parked again, nothing moves it.
      expect({ late: report.late, events: report.first }).toEqual({ late: [], events: [] });
    },
  );
});
