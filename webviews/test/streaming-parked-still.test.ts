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
// as it goes. Each frame records the scroller's offset and the screen top of every row and of every
// block of the reply in view. Between two frames, each item still drawn must have moved by exactly
// the offset's change, the other way; an item gone while the scroll alone would leave it in view is
// a blank flash.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One painted frame: its time, the offset and how far it rests from the end, the view's edges, the
/// last wheel event's time, and the screen top of each row and reply block in view.
type Sample = {
  t: number;
  top: number;
  fromEnd: number;
  input: number;
  view: [number, number];
  items: Record<string, number>;
};
type Probe = Window & {
  __still: { samples: Sample[]; sampling: boolean; done: boolean; input: number; run?: Promise<unknown> };
  __streamingText: { run(options: { cadence: string }): Promise<unknown> };
};
/// An item that moved apart from the scroll, or vanished in view, between two painted frames.
type Event = { t: number; key: string; kind: "moved" | "vanished"; px?: number; scrolled: number };

await requireBrowserLane("streaming-parked-still.test.ts", async () => {
  const round = (value: number) => Math.round(value * 100) / 100;
  /// How long after a wheel event the browser's own scroll may still be easing it in.
  const INPUT_MS = 1_000;

  /// What moved apart from the scroll in `samples`, and how often the offset changed.
  function stillness(samples: Sample[]) {
    const events: Event[] = [];
    let offsetMoves = 0;
    /// Offset changes toward the end, or with no wheel event in the INPUT_MS before them: not the reader's.
    const unprompted: { t: number; px: number }[] = [];
    /// Offset changes, either way, with no wheel event in the INPUT_MS before them.
    const late: { t: number; px: number }[] = [];
    let blockFrames = 0;
    const t0 = samples[0]?.t ?? 0;
    for (let index = 1; index < samples.length; index += 1) {
      const before = samples[index - 1]!;
      const now = samples[index]!;
      const scrolled = now.top - before.top;
      const t = Math.round(now.t - t0);
      if (Object.keys(now.items).some((key) => key.startsWith("block:"))) blockFrames += 1;
      if (Math.abs(scrolled) > 0.5) {
        offsetMoves += 1;
        const recent = now.t - now.input <= INPUT_MS;
        if (!recent) late.push({ t, px: round(scrolled) });
        if (!(recent && scrolled < 0)) unprompted.push({ t, px: round(scrolled) });
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
      frames: samples.length,
      blockFrames,
      offsetMoves,
      fromEnd: round(samples.at(-1)?.fromEnd ?? 0),
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
      w.__still = { samples: [], sampling: false, done: false, input: Number.NEGATIVE_INFINITY };
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      // Each wheel event's time, before the page's own handlers see it.
      const wheel = () => (w.__still.input = performance.now());
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
            fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
            input: w.__still.input,
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
      // While the wheel turns, the offset follows it and, at the latest line, the reply; once the
      // reader has parked again, nothing moves it.
      expect({ late: report.late, events: report.first }).toEqual({ late: [], events: [] });
    },
  );
});
