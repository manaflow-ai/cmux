// Real editor input and safe gallery media for the Messages-style attachment composer.
import { expect, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-inline-caret.browser.test.ts", async () => {
  test("a pasted image stays between words, deletes in one press, and comes back on undo", async () => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    const browser = await chromium.launch({ headless: true });
    const captures = process.env.CMUX_INLINE_CAPTURE_DIR;
    if (captures) await mkdir(captures, { recursive: true });
    try {
      await vite.listen();
      await warmGalleryFrame(vite, "agent-pane.composer", { browser });
      const port = (vite.httpServer!.address() as { port: number }).port;
      for (const theme of ["light", "dark"] as const) {
        const context = await browser.newContext({
          viewport: { width: 1000, height: 760 },
          colorScheme: theme,
          ...(captures ? { recordVideo: { dir: captures, size: { width: 1000, height: 760 } } } : {}),
        });
        const page = await context.newPage();
        try {
          const url = galleryFrame("agent-pane.composer", { variant: "attachment-inline-caret", width: 1000 });
          await page.goto(`http://127.0.0.1:${port}${url}&colorScheme=${theme}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          const atom = page.locator(".acpmux-md [data-inline-attachment]");
          await page.waitForSelector(".acpmux-md [data-inline-attachment] img");
          expect(await atom.count()).toBe(1);
          expect(await atom.locator("img").count()).toBe(1);
          if (captures) await page.screenshot({ path: path.join(captures, `chat-inline-${theme}.png`) });
          await page.locator(".acpmux-md").focus();
          await page.keyboard.press("Backspace");
          expect(await atom.count()).toBe(0);
          await page.keyboard.press("Control+z");
          await page.waitForSelector(".acpmux-md [data-inline-attachment] img");
          expect(await atom.count()).toBe(1);
          expect(await page.locator(".acpmux-md").textContent()).toContain("Compare this with the previous result.");
          const destination = await page.locator(".acpmux-md p").evaluate((paragraph) => {
            const text = paragraph.lastChild!;
            const range = document.createRange();
            range.setStart(text, Math.max(0, (text.textContent?.length ?? 1) - 1));
            range.collapse(true);
            const rect = range.getBoundingClientRect();
            return { x: rect.x, y: rect.y + rect.height / 2 };
          });
          const start = await atom.boundingBox();
          await page.mouse.move(start!.x + start!.width / 2, start!.y + start!.height / 2);
          await page.mouse.down();
          await page.mouse.move(destination.x, destination.y, { steps: 10 });
          await page.mouse.up();
          expect(await atom.count()).toBe(1);
          expect(await atom.evaluate((node) => node.previousSibling?.textContent ?? "")).toContain("result");
          await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "strip" }));
          await page.waitForSelector(".acpmux-attachments img");
          if (captures) await page.screenshot({ path: path.join(captures, `chat-strip-${theme}.png`) });
        } finally {
          await context.close();
        }
      }
    } finally {
      await browser.close();
      await vite.close();
    }
  }, 240_000);
});
