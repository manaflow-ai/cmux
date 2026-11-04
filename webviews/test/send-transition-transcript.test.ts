// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Sending a prompt is one smooth state transition in each starting state (leo-workspace
// design/motion.md "Send states"; Leo, 2026-11-04: "we move all our affected, possibly affected
// elements in the cohesive way"):
// - partly full (the rows fit): nothing already drawn moves, and the prompt's row appears where it rests;
// - full at the latest row: the rows above rise into place over several painted frames, never in one
//   step, also when the prompt's row lands a frame after the send is counted;
// - full and scrolled up: the view glides to the latest row over several frames;
// - under Reduce Motion: the view lands at once.
//
// Real Chromium from Playwright on the agent pane's gallery scene (SendTransition.gallery.tsx).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("send-transition-transcript.test.ts", async () => {
  const ENTRY = "agent-pane.send-transition";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("send-transition-transcript: skipping (run `bunx playwright install chromium`)");
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
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "full-at-bottom" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Every finite animation over, then the scroller's offset and height the same over 16 painted frames.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < 16; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  async function open(variant: string, reducedMotion = false): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    if (reducedMotion) await page.emulateMedia({ reducedMotion: "reduce" });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(".acpmux-scroll .acpmux-row").first().waitFor();
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 60_000,
    });
    await settled(page);
    return page;
  }

  /// Scrolls the transcript up with the mouse wheel, as a reader does, until it is about three
  /// viewports from its end.
  async function park(page: Page) {
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    for (let tries = 0; tries < 20; tries++) {
      const away = await page
        .locator(".acpmux-scroll")
        .evaluate((node) => (node.scrollHeight - node.clientHeight - node.scrollTop) / node.clientHeight);
      if (away >= 3) break;
      await page.mouse.wheel(0, -400);
      await settled(page);
    }
  }

  type Frame = {
    /// The prompt's new row's top and bottom, when it is drawn.
    newTop?: number;
    newBottom?: number;
    /// The row that was last before the send, when it is drawn.
    prevTop?: number;
    /// The tops of every row drawn before the send that is still drawn, by id.
    tops: Record<string, number>;
    scrollTop: number;
    fromEnd: number;
    scrollerBottom: number;
  };

  /// Marks the rows drawn now, clicks Send (in the page, so no pointer event reaches the
  /// transcript), and reads every painted frame for `ms`: frame 0 is the state before the click.
  const watchSend = (page: Page, ms = 900) =>
    page.evaluate(
      (duration) =>
        new Promise<Frame[]>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const drawn = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
          const last = drawn.sort((a, b) => a.getBoundingClientRect().bottom - b.getBoundingClientRect().bottom).at(-1);
          const previous = last?.dataset.rowId;
          const before = new Set(drawn.map((row) => row.dataset.rowId!));
          const sample = (): Frame => {
            const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
            const fresh = rows.find((row) => row.dataset.rowId === "send-new-prompt");
            const prev = rows.find((row) => row.dataset.rowId === previous);
            const tops: Record<string, number> = {};
            for (const row of rows)
              if (before.has(row.dataset.rowId!)) tops[row.dataset.rowId!] = row.getBoundingClientRect().top;
            return {
              newTop: fresh?.getBoundingClientRect().top,
              newBottom: fresh?.getBoundingClientRect().bottom,
              prevTop: prev?.getBoundingClientRect().top,
              tops,
              scrollTop: scroller.scrollTop,
              fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              scrollerBottom: scroller.getBoundingClientRect().bottom,
            };
          };
          const frames: Frame[] = [sample()];
          const start = performance.now();
          window.cmuxAfterPaint(() => {
            frames.push(sample());
            if (performance.now() - start < duration) return;
            resolve(frames);
            return false;
          });
          document.querySelector<HTMLButtonElement>("[data-testid=send-transition-send]")!.click();
        }),
      ms,
    );

  /// How a series moved from its first value: frames strictly between its start and its end, the
  /// largest single-frame step, the total travel, and whether it only ever moved one way.
  const travel = (values: number[], direction: 1 | -1) => {
    const first = values[0]!;
    const final = values.at(-1)!;
    let largest = 0;
    let monotonic = true;
    for (let index = 1; index < values.length; index++) {
      const step = values[index]! - values[index - 1]!;
      largest = Math.max(largest, Math.abs(step));
      if (step * direction < -0.5) monotonic = false;
    }
    const between = values.filter((value) => Math.abs(value - first) > 1 && Math.abs(value - final) > 1).length;
    return { total: Math.abs(final - first), largest, between, monotonic };
  };

  for (const variant of ["full-at-bottom", "full-at-bottom-late"]) {
    test(`${variant}: a send rises the rows above into place over several frames`, async () => {
      const page = await open(variant);
      const frames = await watchSend(page);
      await settled(page);
      const rest = (await watchSend(page, 0))[0]!;
      const tops = frames.map((frame) => frame.prevTop).filter((top): top is number => top !== undefined);
      const moved = travel(tops, -1);
      const summary = { variant, ...moved, tops: tops.map((top) => Math.round(top)) };
      // The row that was last moved up by the prompt's row and the live line.
      expect({ ...summary, rose: moved.total > 40 }).toEqual({ ...summary, rose: true });
      expect({ ...summary, ok: moved.monotonic }).toEqual({ ...summary, ok: true });
      expect({ ...summary, ok: moved.between >= 3 }).toEqual({ ...summary, ok: true });
      expect({ ...summary, ok: moved.largest <= moved.total * 0.6 }).toEqual({ ...summary, ok: true });
      // It rests where the layout puts it, and the prompt's row is above the scroller's foot.
      const final = frames.at(-1)!;
      expect(Math.abs(final.prevTop! - rest.prevTop!)).toBeLessThanOrEqual(1);
      expect(final.fromEnd).toBeLessThanOrEqual(2);
      expect(final.newBottom).toBeDefined();
      expect(final.newBottom!).toBeLessThanOrEqual(final.scrollerBottom + 0.5);
      await page.close();
    });
  }

  for (const variant of ["full-parked", "full-parked-late"]) {
    test(`${variant}: a send glides the view to the latest row over several frames`, async () => {
      const page = await open(variant);
      await park(page);
      const frames = await watchSend(page, 1_400);
      const before = frames[0]!;
      expect(before.fromEnd).toBeGreaterThan(400);
      const offsets = frames.map((frame) => frame.scrollTop);
      const moved = travel(offsets, 1);
      const summary = { variant, ...moved, offsets: offsets.map((top) => Math.round(top)) };
      expect({ ...summary, ok: moved.monotonic }).toEqual({ ...summary, ok: true });
      expect({ ...summary, ok: moved.between >= 3 }).toEqual({ ...summary, ok: true });
      expect({ ...summary, ok: moved.largest <= moved.total * 0.6 }).toEqual({ ...summary, ok: true });
      await settled(page);
      const rest = (await watchSend(page, 0))[0]!;
      expect(rest.fromEnd).toBeLessThanOrEqual(2);
      expect(rest.newTop).toBeDefined();
      expect(rest.newBottom!).toBeLessThanOrEqual(rest.scrollerBottom + 0.5);
      await page.close();
    });
  }

  test("partly-full: nothing drawn moves and the prompt's row appears where it rests", async () => {
    const page = await open("partly-full");
    const frames = await watchSend(page);
    const before = frames[0]!;
    expect(Object.keys(before.tops).length).toBeGreaterThan(2);
    for (const [index, frame] of frames.entries())
      for (const [id, top] of Object.entries(frame.tops)) {
        const at = { index, id, top, was: before.tops[id] };
        expect({ at, still: Math.abs(top - before.tops[id]!) <= 0.5 }).toEqual({ at, still: true });
      }
    const tops = frames.map((frame) => frame.newTop).filter((top): top is number => top !== undefined);
    expect(tops.length).toBeGreaterThan(3);
    for (const [index, top] of tops.entries()) {
      const at = { index, top, first: tops[0] };
      expect({ at, still: Math.abs(top - tops[0]!) <= 0.5 }).toEqual({ at, still: true });
    }
    expect(frames.at(-1)!.newBottom!).toBeLessThanOrEqual(frames.at(-1)!.scrollerBottom + 0.5);
    await page.close();
  });

  test("full-at-bottom under Reduce Motion: a send lands in one frame", async () => {
    const page = await open("full-at-bottom", true);
    const frames = await watchSend(page);
    const tops = frames.map((frame) => frame.prevTop).filter((top): top is number => top !== undefined);
    const final = tops.at(-1)!;
    expect(tops[0]! - final).toBeGreaterThan(40);
    // Every painted frame after the one that moved shows the rest place.
    const firstMoved = tops.findIndex((top) => Math.abs(top - tops[0]!) > 0.5);
    const summary = { firstMoved, tops: tops.map((top) => Math.round(top)) };
    expect({ ...summary, ok: tops.slice(firstMoved).every((top) => Math.abs(top - final) <= 0.5) }).toEqual({
      ...summary,
      ok: true,
    });
    const animating = await page.evaluate(() =>
      document
        .getAnimations()
        .some((each) => each.playState === "running" && each.effect?.getComputedTiming().endTime !== Infinity),
    );
    expect(animating).toBe(false);
    await page.close();
  });
});
