// The opened paste's sheet (composer/PastedTextChip.tsx PastedTextSheet) in a short pane: its bar,
// its text and its actions all fit the pane, the text taking only the room left, so Keep as .txt,
// Edit in Prompt and Close never fall below the pane (review of #38350, F1: at a 200 px pane both
// actions were below it, and nothing scrolled to them). Its text is selectable, so a person can copy
// a part of the paste (F2: it inherited the page's `user-select: none`).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-paste-view-fit.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-paste-view-fit: skipping (run `bunx playwright install chromium`)");
    describe.skip("paste viewer fit", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.composer-paste-chip";
  const VARIANT = "sheet-open";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  }, 170_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function openSheet(height: number) {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 640, height } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 640, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    await page.waitForSelector('[role="dialog"] .acpmux-attachment-keep-file', { timeout: 60_000 });
    return page;
  }

  for (const height of [160, 200, 320])
    test(`at a ${height}px pane the sheet's bar, text and actions all fit the pane`, async () => {
      const page = await openSheet(height);
      try {
        const found = await page.evaluate(() => {
          const dialog = document.querySelector<HTMLElement>('[role="dialog"]')!;
          const inside = (node: Element) => {
            const box = node.getBoundingClientRect();
            return box.top >= -0.5 && box.bottom <= innerHeight + 0.5 && box.height > 0;
          };
          const buttons = [...dialog.querySelectorAll<HTMLButtonElement>("button")].map((button) => ({
            name: button.getAttribute("aria-label") ?? button.textContent ?? "",
            inside: inside(button),
          }));
          const text = dialog.querySelector<HTMLElement>(".acpmux-paste-view__text")!;
          return {
            dialogInside: dialog.getBoundingClientRect().bottom <= innerHeight + 0.5,
            buttons,
            textHeight: text.getBoundingClientRect().height,
            textScrolls: text.scrollHeight > text.clientHeight,
          };
        });
        expect(found.dialogInside).toBe(true);
        expect(found.buttons.map((button) => button.name).sort()).toEqual(["Close", "Edit in Prompt", "Keep as .txt"]);
        for (const button of found.buttons) expect(button).toEqual({ name: button.name, inside: true });
        // The text keeps a scroller, however little room is left for it.
        expect(found.textHeight).toBeGreaterThan(0);
        expect(found.textScrolls).toBe(true);
      } finally {
        await page.close();
      }
    });

  test("the sheet's text is selectable: a person can copy a part of the paste", async () => {
    const page = await openSheet(560);
    try {
      const found = await page.evaluate(() => {
        const text = document.querySelector<HTMLElement>('[role="dialog"] .acpmux-paste-view__text')!;
        const range = document.createRange();
        range.setStart(text.firstChild!, 0);
        range.setEnd(text.firstChild!, "Ran a command".length);
        const selection = getSelection()!;
        selection.removeAllRanges();
        selection.addRange(range);
        return { userSelect: getComputedStyle(text).userSelect, selected: selection.toString() };
      });
      expect(found.userSelect).toBe("text");
      expect(found.selected).toBe("Ran a command");
      // A real drag across its first line selects it too.
      await page.evaluate(() => getSelection()!.removeAllRanges());
      const line = page.locator('[role="dialog"] .acpmux-paste-view__text');
      const box = (await line.boundingBox())!;
      await page.mouse.move(box.x + 16, box.y + 22);
      await page.mouse.down();
      await page.mouse.move(box.x + 200, box.y + 22, { steps: 8 });
      await page.mouse.up();
      expect((await page.evaluate(() => getSelection()!.toString())).length).toBeGreaterThan(5);
    } finally {
      await page.close();
    }
  });
});
