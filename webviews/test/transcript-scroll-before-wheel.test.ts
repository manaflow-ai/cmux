// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolled up while a reply streams, the reader stays where they scrolled (Lawrence, 2026-11-07:
// "scrolling up is broken", a recording of the agent chat pulled back to the bottom gesture after
// gesture while the agent ran a command, with no Jump to latest ever showing).
//
// The pane's wheel listeners on a trackpad are passive, so WebKit scrolls the transcript on its
// scrolling thread and hands the page the wheel event afterwards. A streamed snapshot that commits
// in between saw the offset risen with no input yet, took it for layout work, and pinned the view
// back to the bottom. The case here moves the offset first, lets a snapshot commit before the wheel,
// then delivers the wheel late, as the app's WebKit does.
//
// Real Chromium and WebKit from Playwright; CI fails the file when they cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-scroll-before-wheel.test.ts", async () => {
  setDefaultTimeout(120_000);
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
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
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
  const history = Array.from({ length: 18 }, (_, index) => [
    row(`history-user-${index}`, "user", `Prompt ${index}`),
    row(`history-answer-${index}`, "assistant", paragraph(index)),
  ]).flat();
  const streaming = (paragraphs: number, version: number) =>
    [
      ...history,
      row("stream", "assistant", Array.from({ length: paragraphs }, (_, index) => paragraph(18 + index)).join("\n\n"), {
        version,
        streaming: true,
      }),
    ] as Row[];
  const frames = (page: Page, count = 2) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop;
    });
  const following = (page: Page) =>
    page.evaluate(
      () => (window as unknown as { __followSnapshot(): { following: boolean } }).__followSnapshot().following,
    );

  /// A chat following a streaming reply at its latest line.
  const followedStream = async (browser: Browser) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRowsSync" in window);
    await show(page, streaming(1, 1));
    await frames(page, 4);
    await show(page, streaming(2, 2));
    await frames(page, 4);
    expect(await fromEnd(page)).toBeLessThanOrEqual(1);
    expect(await following(page)).toBe(true);
    return page;
  };
  /// The wheel the browser already scrolled for, reaching the page late.
  const lateWheel = (page: Page, deltaY: number) =>
    page.evaluate((delta) => {
      document
        .querySelector<HTMLElement>(".acpmux-scroll")!
        .dispatchEvent(new WheelEvent("wheel", { deltaY: delta, bubbles: true, cancelable: true }));
    }, deltaY);

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    describe(name, () => {
      const launch = async () => {
        let browser = browsers.get(name);
        if (!browser) {
          browser = await engine.launch({ headless: true });
          browsers.set(name, browser);
        }
        return browser;
      };

      test("a streamed snapshot that commits before the wheel keeps the reader's scroll up", async () => {
        const page = await followedStream(await launch());
        try {
          // The scrolling thread's move, then a snapshot already queued, in one task: no scroll event,
          // no wheel, between them.
          const committed = await page.evaluate(
            (rows) => {
              const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              node.scrollTop -= 120;
              (window as unknown as { __showRowsSync(rows: unknown): void }).__showRowsSync(rows);
              return node.scrollHeight - node.clientHeight - node.scrollTop;
            },
            streaming(3, 3),
          );
          await lateWheel(page, -120);
          await frames(page, 3);
          await show(page, streaming(4, 4));
          await frames(page, 4);
          const state = { committed, end: await fromEnd(page), following: await following(page) };
          console.log(`scroll-before-wheel ${name}: ${JSON.stringify(state)}`);
          // Base: the snapshot pinned the view to the bottom (committed 0).
          expect(state.committed).toBeGreaterThanOrEqual(119);
          expect(state.end).toBeGreaterThanOrEqual(119);
          expect(state.following).toBe(false);
        } finally {
          await page.close();
        }
      });

      test("a rise of a pixel or two that no input made stays followed", async () => {
        // WebKit itself moves a followed offset a pixel or so above the latest line as a reply grows
        // (cx-02st5): inside the follow deadband that is layout work, never the reader's scroll.
        const page = await followedStream(await launch());
        try {
          await page.evaluate(
            (rows) => {
              const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              node.scrollTop -= 2;
              (window as unknown as { __showRowsSync(rows: unknown): void }).__showRowsSync(rows);
            },
            streaming(3, 3),
          );
          await frames(page, 4);
          expect(await fromEnd(page)).toBeLessThanOrEqual(1);
          expect(await following(page)).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("a viewport that grows at the end still clamps without releasing follow", async () => {
        const page = await followedStream(await launch());
        try {
          await page.setViewportSize({ width: 900, height: 700 });
          await frames(page, 4);
          await show(page, streaming(3, 3));
          await frames(page, 4);
          expect(await fromEnd(page)).toBeLessThanOrEqual(1);
          expect(await following(page)).toBe(true);
        } finally {
          await page.close();
        }
      });
    });
  }
});
