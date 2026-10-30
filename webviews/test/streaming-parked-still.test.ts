// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-10-27: "im still getting flickering rerenderings on certain weird scroll things when
// you're streaming text and im on some in between zone". A reader who scrolled partway up while a
// reply streams (neither at the latest line nor far away: the reply still on screen) has let go of
// the follow, so nothing they see may move, vanish or redraw while the reply grows below them.
//
// The page is the streaming-text harness (browser/streaming-text.harness.tsx): the real
// VirtualTranscript over a chat's history with the bottom stack over its foot, streaming the
// 5,000-character Markdown reply at Claude's cadence. Mid-stream the test scrolls up with a real
// wheel by a few distances, waits for the wheel's glide to land, then samples every painted frame
// until the stream has drained: the screen top of each row and of each of the reply's blocks in
// view, and the scroller's offset. Any of them moving, a row or block in view leaving the DOM, or
// the offset changing with no input is the flicker.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Sample = { t: number; top: number; items: Record<string, number> };
type Probe = Window & {
  __parked: { samples: Sample[]; sampling: boolean; run?: Promise<unknown> };
  __streamingText: { run(options: { cadence: string }): Promise<unknown> };
};

/// One item that moved or vanished between two painted frames while the reader was parked.
type Event = { t: number; key: string; kind: "moved" | "vanished"; px?: number };

await requireBrowserLane("streaming-parked-still.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`streaming-parked-still: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("streaming parked still", () => test("no engine", () => {}));
    return;
  }
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

  async function park(name: string, upPx: number) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/streaming-text.html`);
    await page.waitForFunction(() => "__streamingText" in window);
    await page.getByText("History answer 6.").waitFor();
    // fixed-wait: nothing marks the page's start-up as done
    await page.waitForTimeout(500);
    await page.evaluate(() => {
      const w = window as unknown as Probe;
      w.__parked = { samples: [], sampling: false };
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const tick = (t: number) => {
        if (w.__parked.sampling) {
          const view = scroller.getBoundingClientRect();
          const items: Record<string, number> = {};
          const inView = (rect: DOMRect) => rect.height > 0 && rect.bottom > view.top && rect.top < view.bottom;
          for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
            const rect = row.getBoundingClientRect();
            if (inView(rect)) items[`row:${row.dataset.rowId}`] = rect.top;
          }
          const reply = scroller.querySelector<HTMLElement>('.acpmux-row[data-row-id="live-answer"] .cv-md');
          if (reply)
            [...reply.children].forEach((child, index) => {
              const rect = child.getBoundingClientRect();
              if (inView(rect)) items[`block:${index}:${child.tagName}`] = rect.top;
            });
          w.__parked.samples.push({ t, top: scroller.scrollTop, items });
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      w.__parked.run = w.__streamingText.run({ cadence: "claude" });
    });
    // Once the reply is taller than a screen, the reader scrolls up into the in-between zone.
    await page.waitForFunction(
      () =>
        (document.querySelector('.acpmux-row[data-row-id="live-answer"] .cv-md')?.textContent?.length ?? 0) > 1_600,
      undefined,
      { timeout: 30_000 },
    );
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 3);
    await page.mouse.wheel(0, -upPx);
    // The wheel's glide lands (wheelGlide.ts) before the parked frames count.
    // fixed-wait: the glide has no done marker; it lands well inside this window
    await page.waitForTimeout(600);
    const parkedAt = await page.evaluate(() => {
      const w = window as unknown as Probe;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      w.__parked.sampling = true;
      return {
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        replyInView: !!scroller.querySelector('.acpmux-row[data-row-id="live-answer"]'),
      };
    });
    await page.evaluate(() => (window as unknown as Probe).__parked.run);
    const samples = await page.evaluate(() => {
      const w = window as unknown as Probe;
      w.__parked.sampling = false;
      return w.__parked.samples;
    });
    await page.close();
    const events: Event[] = [];
    let offsetMoves = 0;
    const t0 = samples[0]?.t ?? 0;
    for (let index = 1; index < samples.length; index += 1) {
      const before = samples[index - 1]!;
      const now = samples[index]!;
      if (Math.abs(now.top - before.top) > 0.5) offsetMoves += 1;
      for (const [key, top] of Object.entries(before.items)) {
        const t = Math.round(now.t - t0);
        if (!(key in now.items)) {
          // A row or block that scrolled out of view is not a flicker; one still on screen is.
          if (Math.abs(now.top - before.top) <= 0.5) events.push({ t, key, kind: "vanished" });
          continue;
        }
        const px = now.items[key]! - top;
        if (Math.abs(px) > 0.5) events.push({ t, key, kind: "moved", px: Math.round(px * 100) / 100 });
      }
    }
    return { upPx, parkedAt, frames: samples.length, offsetMoves, events: events.length, first: events.slice(0, 12) };
  }

  /// A reader moving through the in-between zone while the reply streams: a trackpad's small wheel
  /// steps up from the latest line, then back down to it, twice. Every painted frame, each row and
  /// block still on screen must have moved exactly opposite to the offset (the scroll), and nothing
  /// still inside the view may leave the DOM.
  async function wander(name: string, step: number) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/streaming-text.html`);
    await page.waitForFunction(() => "__streamingText" in window);
    await page.getByText("History answer 6.").waitFor();
    // fixed-wait: nothing marks the page's start-up as done
    await page.waitForTimeout(500);
    await page.evaluate(() => {
      const w = window as unknown as Probe;
      w.__parked = { samples: [], sampling: false };
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const tick = (t: number) => {
        if (w.__parked.sampling) {
          const view = scroller.getBoundingClientRect();
          const items: Record<string, number> = {};
          const inView = (rect: DOMRect) => rect.height > 0 && rect.bottom > view.top && rect.top < view.bottom;
          for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
            const rect = row.getBoundingClientRect();
            if (inView(rect)) items[`row:${row.dataset.rowId}`] = rect.top;
          }
          const reply = scroller.querySelector<HTMLElement>('.acpmux-row[data-row-id="live-answer"] .cv-md');
          if (reply)
            [...reply.children].forEach((child, index) => {
              const rect = child.getBoundingClientRect();
              if (inView(rect)) items[`block:${index}:${child.tagName}`] = rect.top;
            });
          w.__parked.samples.push({ t, top: scroller.scrollTop, items, view: [view.top, view.bottom] } as Sample);
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      w.__parked.run = w.__streamingText.run({ cadence: "claude" });
    });
    await page.waitForFunction(
      () =>
        (document.querySelector('.acpmux-row[data-row-id="live-answer"] .cv-md')?.textContent?.length ?? 0) > 1_200,
      undefined,
      { timeout: 30_000 },
    );
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 3);
    await page.evaluate(() => ((window as unknown as Probe).__parked.sampling = true));
    for (let round = 0; round < 2; round += 1)
      for (const direction of [-1, 1])
        for (let index = 0; index < 14; index += 1) {
          await page.mouse.wheel(0, direction * step);
          // fixed-wait: a trackpad's wheel events come about two frames apart
          await page.waitForTimeout(32);
        }
    // fixed-wait: the last glide lands
    await page.waitForTimeout(400);
    const samples = await page.evaluate(() => {
      const w = window as unknown as Probe;
      w.__parked.sampling = false;
      return w.__parked.samples as (Sample & { view: [number, number] })[];
    });
    await page.evaluate(() => (window as unknown as Probe).__parked.run);
    await page.close();
    const events: (Event & { scrolled: number })[] = [];
    const t0 = samples[0]?.t ?? 0;
    for (let index = 1; index < samples.length; index += 1) {
      const before = samples[index - 1]!;
      const now = samples[index]!;
      const scrolled = now.top - before.top;
      const t = Math.round(now.t - t0);
      for (const [key, top] of Object.entries(before.items)) {
        const expected = top - scrolled;
        if (!(key in now.items)) {
          // Still inside the view where the scroll alone would put it, but gone: a blank flash.
          if (expected > now.view[0] + 2 && expected < now.view[1] - 2)
            events.push({ t, key, kind: "vanished", scrolled: Math.round(scrolled * 100) / 100 });
          continue;
        }
        const px = now.items[key]! - expected;
        if (Math.abs(px) > 0.5)
          events.push({ t, key, kind: "moved", px: Math.round(px * 100) / 100, scrolled: Math.round(scrolled * 100) / 100 });
      }
    }
    const frames = new Set(events.map((event) => event.t)).size;
    return { step, frames: samples.length, badFrames: frames, events: events.length, first: events.slice(0, 16) };
  }

  test.each(engines.flatMap(([name]) => [24, 60].map((px) => `${name} ${px}`)))(
    "%s px steps: scrolling through the in-between zone while a reply streams moves nothing but the scroll",
    async (label) => {
      const [name, px] = label.split(" ") as [string, string];
      const report = await wander(name, Number(px));
      console.log(`streaming-wander ${label}: ${JSON.stringify(report)}`);
      expect(report.frames).toBeGreaterThan(30);
      expect(report.first).toEqual([]);
    },
  );

  test.each(engines.flatMap(([name]) => [60, 160, 320, 640].map((px) => `${name} ${px}`)))(
    "%s px up: a parked reader's view holds still while the reply streams below",
    async (label) => {
      const [name, px] = label.split(" ") as [string, string];
      const report = await park(name, Number(px));
      console.log(`streaming-parked-still ${label}: ${JSON.stringify(report)}`);
      expect(report.frames).toBeGreaterThan(30);
      expect({ offsetMoves: report.offsetMoves, events: report.first }).toEqual({ offsetMoves: 0, events: [] });
    },
  );
});
