// A fenced code card keeps its height while its highlighted view replaces the plain one (cx-wdenv).
// The transcript draws a code block as plain text, then swaps in the highlighted card once its
// chunk loads; that card's body stayed empty until the highlight worker answered, so every code
// block collapsed by its lines and grew back a moment later, moving the paragraphs under it. A
// play that focused the composer then (chat-palette-actions' Copy Last Code Block) graded the
// 0.0058 layout shift and failed about one run in three.
//
// Real Chromium on the transcript gallery's copy-last-code-block chat (three fenced blocks); each
// card's height is recorded from the first frame it is drawn until the highlight lands.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("code-block-highlight-height.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("code-block-highlight-height: skipping (run `bunx playwright install chromium`)");
    describe.skip("code block highlight height", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.transcript&variant=copy-last-code-block`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 760, height: 560 } });
    await warm.goto(stageURL());
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a code card is never shorter than its plain text while it highlights", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.addInitScript(() => {
      // Each frame: the height of every code card, top to bottom.
      const frames: number[][] = [];
      (window as unknown as { codeCardHeights: number[][] }).codeCardHeights = frames;
      const sample = () => {
        const cards = [...document.querySelectorAll(".cv-codeblock")];
        if (cards.length) frames.push(cards.map((card) => Math.round(card.getBoundingClientRect().height)));
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });
    await page.goto(stageURL());
    // Highlighted: every card's body has Pierre's painted lines.
    await page.waitForFunction(() => {
      const bodies = [...document.querySelectorAll(".cv-codeblock__body")];
      return bodies.length === 3 && bodies.every((body) => body.shadowRoot?.querySelector("[data-line]"));
    });
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const frames = await page.evaluate(() => (window as unknown as { codeCardHeights: number[][] }).codeCardHeights);
    await page.close();
    const drawn = frames.filter((heights) => heights.length === 3);
    const first = drawn[0]!;
    const last = drawn.at(-1)!;
    // Each card's lowest height while it highlights is the height it drew at first and ends at. A
    // card is a fractional height (its 45.5px header), so a rounded one can read a pixel less where
    // rows above it settle at another sub-pixel offset; a collapse is whole lines.
    const lowest = first.map((_, card) => Math.min(...drawn.map((heights) => heights[card]!)));
    const collapsed = lowest.map((height, card) => first[card]! - height > 1);
    expect({ first, collapsed, last }).toEqual({ first, collapsed: first.map(() => false), last: first });
  });
});
