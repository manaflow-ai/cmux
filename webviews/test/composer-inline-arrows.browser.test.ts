// A placed attachment moves like one character under the arrow keys (Leo, 2026-11-01: "when i paste
// images and the inline attachments are in the composer i dont want left arrow to be selecting
// them??? just jump over them treat them like it's one character"): Left and Right step the caret
// over the chip and never select it, Shift+arrow extends over it as one unit, and Backspace takes
// it in one press. Both engines: the app's WebKit and the gallery's Chromium.
import { expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Page, webkit } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-inline-arrows.browser.test.ts", async () => {
  /** The text right before and after the placed attachment, and whether the chip is node-selected. */
  const around = (page: Page) =>
    page.locator(".acpmux-md [data-inline-attachment]").evaluate((chip) => ({
      before: chip.previousSibling?.textContent ?? "",
      after: chip.nextSibling?.textContent ?? "",
      selected: chip.classList.contains("ProseMirror-selectednode"),
    }));

  test("arrow keys step over a placed attachment as one character", async () => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    try {
      await vite.listen();
      const port = (vite.httpServer!.address() as { port: number }).port;
      for (const engine of [chromium, webkit]) {
        const browser = await engine.launch({ headless: true });
        try {
          await warmGalleryFrame(vite, "agent-pane.composer", { browser });
          const page = await browser.newPage({ viewport: { width: 1000, height: 760 } });
          const url = galleryFrame("agent-pane.composer", { variant: "attachment-inline-caret", width: 1000 });
          await page.goto(`http://127.0.0.1:${port}${url}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          await page.waitForSelector(".acpmux-md [data-inline-attachment] img");
          const chip = page.locator(".acpmux-md [data-inline-attachment]");
          await page.locator(".acpmux-md").focus();
          const start = await around(page);

          // The caret sits after the chip: Left lands before it, Right after it, neither selects it.
          await page.keyboard.press("ArrowLeft");
          expect((await around(page)).selected, engine.name()).toBe(false);
          await page.keyboard.type("L");
          expect(await around(page), engine.name()).toEqual({
            before: `${start.before}L`,
            after: start.after,
            selected: false,
          });
          await page.keyboard.press("ArrowRight");
          expect((await around(page)).selected, engine.name()).toBe(false);
          await page.keyboard.type("R");
          expect(await around(page), engine.name()).toEqual({
            before: `${start.before}L`,
            after: `R${start.after}`,
            selected: false,
          });

          // Shift+Left from after the chip takes the chip alone, as one character.
          await page.keyboard.press("ArrowLeft");
          await page.keyboard.press("Shift+ArrowLeft");
          await page.keyboard.press("Backspace");
          expect(await chip.count(), engine.name()).toBe(0);
          expect(await page.locator(".acpmux-md").textContent(), engine.name()).toBe(`${start.before}LR${start.after}`);
          await page.close();
        } finally {
          await browser.close();
        }
      }
    } finally {
      await vite.close();
    }
  }, 300_000);
});
