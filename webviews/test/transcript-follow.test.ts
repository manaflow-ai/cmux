// A new chat follows its reply (dogfood run 5): once a streaming reply grows past the
// viewport, the view stays at its latest line, as Codex and Claude do, and a turn sent after
// it comes into view. On the 2026-10-12 nightly the view stayed on the first turn instead.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-follow.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-follow: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript follow", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const paragraph = (index: number) =>
    `Paragraph ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
    "then watched the light sweep the water for a while before going back down.";
  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  const frames = (page: Page, count = 2) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  /// How far the latest row's text ends below the bottom of the view (its own bottom padding is
  /// blank), in the first painted frame after any glide has landed.
  const belowView = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<number>((resolve) => {
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            // A glide is a finite animation still running in the view; a looping one (a streaming
            // mark) never lands, and a finished one that holds its last frame stays listed.
            const gliding = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            if (gliding) return true;
            const view = scroller.getBoundingClientRect();
            const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")];
            const last = rows.reduce((low, row) =>
              row.getBoundingClientRect().bottom > low.getBoundingClientRect().bottom ? row : low,
            );
            const text = last.getBoundingClientRect().bottom - parseFloat(getComputedStyle(last).paddingBottom);
            resolve(Math.round(text - view.bottom));
            return false;
          });
        }),
    );

  test("a reply that streams past the viewport is followed, and so is the next turn", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    const first = [
      row("t0-user", "user", "Say hi in three words."),
      row("t0-answer", "assistant", "Hello there, friend!"),
      row("t0-end", "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
    ];
    await show(page, first);
    await frames(page);
    const prompt = row("t1-user", "user", "Write a short story about a lighthouse keeper.");
    let text = "";
    for (let index = 0; index < 30; index += 1) {
      text += `${index ? "\n\n" : ""}${paragraph(index)}`;
      await show(page, [
        ...first,
        prompt,
        row("t1-answer", "assistant", text, { version: index + 1, streaming: true }),
      ]);
      await frames(page);
    }
    const overflow = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight;
    });
    expect(overflow).toBeGreaterThan(560);
    expect(await belowView(page)).toBeLessThanOrEqual(2);

    const answered = [
      ...first,
      prompt,
      row("t1-answer", "assistant", text, { version: 31 }),
      row("t1-end", "turnSummary", undefined, { status: "completed", durationMs: 9_000 }),
    ];
    await show(page, answered);
    await frames(page);
    await show(page, [...answered, row("t2-user", "user", "Now give it a title.")]);
    await frames(page);
    await show(page, [
      ...answered,
      row("t2-user", "user", "Now give it a title."),
      row("t2-answer", "assistant", "The Other Light", { streaming: true }),
    ]);
    await frames(page);
    expect(await belowView(page)).toBeLessThanOrEqual(2);
    await page.close();
  });

  test("a touch tap keeps a short streaming reply's reserved queue room", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 }, hasTouch: true });
    await installPaintedFrames(page);
    if (process.env.CMUX_TOUCH_CAPTURE?.includes("dark")) await page.emulateMedia({ colorScheme: "dark" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate(() => (window as unknown as { __touchDock(queued: boolean): void }).__touchDock(true));
    const history = Array.from({ length: 18 }, (_, index) => [
      row(`room-user-${index}`, "user", `Prompt ${index}`),
      row(`room-answer-${index}`, "assistant", paragraph(index)),
    ]).flat();
    await show(page, [...history, row("room-stream", "assistant", "Short streaming reply", { streaming: true })]);
    await frames(page, 4);
    await page.evaluate(() => (window as unknown as { __touchDock(queued: boolean): void }).__touchDock(false));
    await frames(page, 2);
    const bottom = () =>
      page.locator('[data-row-id="room-stream"]').evaluate((node) => node.getBoundingClientRect().bottom);
    const before = await bottom();
    // A tap on the transcript's text, not its pane edge: the prompt rail sits at the pane edge (#26641),
    // and a tap on one of its ticks jumps to that prompt.
    const spot = await page.evaluate(() => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      for (const node of document.querySelectorAll<HTMLElement>('[data-row-id^="room-answer-"]')) {
        const box = node.getBoundingClientRect();
        if (box.top >= view.top && box.bottom <= view.top + view.height / 2)
          return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
      }
      return undefined;
    });
    expect(spot).toBeDefined();
    const onRail = await page.evaluate(
      ({ x, y }) => Boolean(document.elementFromPoint(x, y)?.closest(".acpmux-minimap")),
      spot!,
    );
    expect(onRail).toBe(false);
    await page.touchscreen.tap(spot!.x, spot!.y);
    await frames(page, 3);
    const moved = (await bottom()) - before;
    if (process.env.CMUX_TOUCH_CAPTURE) {
      console.log(`TOUCH_CAPTURE_${process.env.CMUX_TOUCH_CAPTURE}=${(await page.screenshot()).toString("base64")}`);
    }
    console.log(`touch tap reserved-room movement: ${moved}px`);
    expect(Math.abs(moved)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("a queued latest frame cannot restore follow after upward intent at the same offset", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const history = Array.from({ length: 18 }, (_, index) => [
        row(`history-user-${index}`, "user", `Prompt ${index}`),
        row(`history-answer-${index}`, "assistant", paragraph(index)),
      ]).flat();
      const text = paragraph(18);
      await show(page, [...history, row("stream", "assistant", text, { streaming: true })]);
      await frames(page, 3);
      expect(await belowView(page)).toBeLessThanOrEqual(2);
      const input = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const before = node.scrollTop;
        // Queue a followed scroll frame, then deliver upward intent before its physical default.
        // A synthetic wheel has no default; hold that write to isolate the same-offset RAF path.
        node.dispatchEvent(new Event("scroll"));
        node.dispatchEvent(new WheelEvent("wheel", { deltaY: -2, bubbles: true, cancelable: true }));
        return { before, after: node.scrollTop };
      });
      expect(input.after).toBe(input.before);
      await frames(page, 2);
      await show(page, [
        ...history,
        row("stream", "assistant", `${text}\n\n${paragraph(19)}\n\n${paragraph(20)}`, {
          version: 2,
          streaming: true,
        }),
      ]);
      await frames(page, 3);
      const state = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return {
          gap: node.scrollHeight - node.clientHeight - node.scrollTop,
          fadeBottom: node.dataset.fadeBottom === "true",
          intent: (window as unknown as { __followSnapshot(): { following: boolean } }).__followSnapshot().following,
        };
      });
      console.log(`queued-follow-intent: ${JSON.stringify({ input, ...state })}`);
      expect(state.intent).toBe(false);
      expect(state.gap).toBeGreaterThan(20);
      // The rendered reader state must agree with intent: growing rows below remain indicated.
      expect(state.fadeBottom).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("a small upward wheel before a stream snapshot releases bottom follow", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);

    const history = Array.from({ length: 18 }, (_, index) => [
      row(`history-user-${index}`, "user", `Prompt ${index}`),
      row(`history-answer-${index}`, "assistant", paragraph(index)),
    ]).flat();
    let text = paragraph(18);
    const current = [...history, row("stream", "assistant", text, { version: 1, streaming: true })];
    await show(page, current);
    await frames(page, 3);
    expect(await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop)).toBeGreaterThan(
      0,
    );

    // A viewer at the bottom follows the same stream update.
    text += `\n\n${paragraph(19)}`;
    await show(page, [...history, row("stream", "assistant", text, { version: 2, streaming: true })]);
    await frames(page, 2);
    expect(await belowView(page)).toBeLessThanOrEqual(2);

    // The capture listener updates rows before the browser delivers the scroll event. A two-pixel
    // wheel is below the stray-scroll deadband, but it is still an intentional move up and must
    // release following before the streamed layout pass can pin the view back to the bottom.
    const beforeHeight = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollHeight);
    text += `\n\n${paragraph(20)}\n\n${paragraph(21)}`;
    const next = [...history, row("stream", "assistant", text, { version: 3, streaming: true })];
    await page.evaluate((rows) => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.addEventListener(
        "wheel",
        () => {
          (window as unknown as { __showRowsSync(rows: unknown): void }).__showRowsSync(rows);
        },
        { capture: true, once: true },
      );
    }, next);
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 120);
    await page.mouse.wheel(0, -2);
    await frames(page, 3);
    await page.waitForFunction((height) => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll");
      return node !== null && node.scrollHeight >= height + 20;
    }, beforeHeight);
    const metrics = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return {
        currentHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
        scrollTop: node.scrollTop,
        fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop,
        follow: (window as unknown as { __followSnapshot(): { following: boolean } }).__followSnapshot().following,
      };
    });
    console.log(`stream follow metrics: ${JSON.stringify({ beforeHeight, ...metrics })}`);
    expect(metrics.fromEnd).toBeGreaterThan(20);
    await page.close();
  });
});
