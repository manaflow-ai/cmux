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
      const target = Math.max(0, node.scrollTop - 2);
      node.addEventListener(
        "wheel",
        () => {
          node.scrollTop = target;
          (window as unknown as { __showRowsSync(rows: unknown): void }).__showRowsSync(rows);
        },
        { capture: true, once: true },
      );
      node.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -2 }));
      return target;
    }, next);
    await frames(page, 3);
    await page.waitForFunction((height) => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll");
      return node !== null && node.scrollHeight >= height + 20;
    }, beforeHeight);
    expect(
      await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return node.scrollHeight - node.clientHeight - node.scrollTop;
      }),
    ).toBeGreaterThan(20);
    await page.close();
  });
});
