// A Cloud start's view and the started chat's first turn draw the prompt and the status line in one place
// (cmux#55540). The person's recording: the bubble sat 24px in from the composer's right edge and the
// "Starting your Cloud machine" line 17px right of where the chat's Thinking line then drew, and both
// jumped when the machine's page took the start's place. CloudStartView kept a column of its own
// (720px, 16px of padding, 24px down); it now lays out on the transcript's column, inset, lead and top.
//
// Real Chromium on the pane's CSS (browser/cloud-start-handoff.harness.tsx): at each pane width, the
// start's bubble and the chat's have one right edge and one top, and the start's status words start
// where the chat's Thinking words do.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Boxes = { bubble: { right: number; top: number; left: number }; status: number };

await requireBrowserLane("cloud-start-handoff-browser.test.ts", async () => {
  const PAGE = "/test/browser/cloud-start-handoff.html";
  const TOLERANCE = 1;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("cloud-start-handoff-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("Cloud start hand-off layout", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let page: Page;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
    await installPaintedFrames(page);
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
    await page.waitForFunction(() => "__handoff" in window);
    await page.evaluate(() =>
      (window as unknown as { __handoff: { loadStrings(): Promise<void> } }).__handoff.loadStrings(),
    );
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Where `shown`'s prompt bubble sits and where its status words (the start's stage line, the chat's
  /// Thinking line) start, at pane width `width`.
  const measure = (shown: "start" | "chat", width: number) =>
    page.evaluate(
      async ({ shown, width }) => {
        (window as unknown as { __handoff: { show(next: string, options: { width: number }): void } }).__handoff.show(
          shown,
          { width },
        );
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const bubble = document.querySelector<HTMLElement>(".cv-user__bubble");
        const words = document.querySelector<HTMLElement>("output.cv-thinking");
        if (!bubble || !words) throw new Error(`${shown}: no bubble or status line drawn`);
        // The first glyph's left edge: the words, not their box (a box may start before them).
        const range = document.createRange();
        const text = [...words.querySelectorAll("*"), words]
          .flatMap((node) => [...node.childNodes])
          .find((node) => node.nodeType === Node.TEXT_NODE && node.textContent?.trim());
        if (!text) throw new Error(`${shown}: the status line has no words`);
        range.setStart(text, text.textContent!.search(/\S/));
        range.setEnd(text, text.textContent!.search(/\S/) + 1);
        const box = bubble.getBoundingClientRect();
        return {
          bubble: { right: box.right, top: box.top, left: box.left },
          status: range.getBoundingClientRect().left,
        };
      },
      { shown, width },
    ) as Promise<Boxes>;

  describe("Cloud start hand-off layout", () => {
    for (const width of [1400, 900, 520]) {
      test(`the start's prompt and status line sit where the chat's will (${width}px pane)`, async () => {
        const start = await measure("start", width);
        const chat = await measure("chat", width);
        expect(Math.abs(start.bubble.right - chat.bubble.right)).toBeLessThanOrEqual(TOLERANCE);
        expect(Math.abs(start.bubble.left - chat.bubble.left)).toBeLessThanOrEqual(TOLERANCE);
        expect(Math.abs(start.bubble.top - chat.bubble.top)).toBeLessThanOrEqual(TOLERANCE);
        expect(Math.abs(start.status - chat.status)).toBeLessThanOrEqual(TOLERANCE);
      });
    }
  });
});
