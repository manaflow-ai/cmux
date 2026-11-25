// Two attachments in the prompt's text trade places by a drag from anywhere on a thumbnail (Leo,
// 2026-11-02: "I can't drag to reorder these inline attachments very easily anymore"). The press
// lands on the thumbnail's centre, where the open button covers the picture, so the editor must
// still take it as a drag of the chip; the × stays hidden until the pointer is on the chip, is
// small, and is never where a drag starts. Both engines: the app's WebKit and the gallery's Chromium.
import { expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Page, webkit } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-inline-reorder.browser.test.ts", async () => {
  const CHIP = ".acpmux-md [data-inline-attachment]";
  const ids = (page: Page) =>
    page.locator(CHIP).evaluateAll((chips) => chips.map((chip) => (chip as HTMLElement).dataset.inlineAttachment));
  const removeOpacity = (page: Page, index: number) =>
    page
      .locator(CHIP)
      .nth(index)
      .locator(".acpmux-attachment-remove")
      .evaluate((button) => Number(getComputedStyle(button).opacity));

  test("a press on a thumbnail's centre drags it past the next one; the × shows only on hover", async () => {
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
          const url = galleryFrame("agent-pane.composer", { variant: "attachment-inline-reorder", width: 1000 });
          await page.goto(`http://127.0.0.1:${port}${url}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          await page.waitForFunction((chip) => document.querySelectorAll(`${chip} img`).length === 2, CHIP);
          const name = engine.name();

          // The pointer away: no × on either thumbnail. On one: its × shows, small, in its corner.
          await page.mouse.move(5, 5);
          expect(await removeOpacity(page, 0), name).toBe(0);
          expect(await removeOpacity(page, 1), name).toBe(0);
          const first = page.locator(CHIP).nth(0);
          const box = (await first.locator(".acpmux-attachment-image").boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await page.waitForFunction(
            (chip) =>
              Number(getComputedStyle(document.querySelector(`${chip} .acpmux-attachment-remove`)!).opacity) === 1,
            CHIP,
          );
          const remove = (await first.locator(".acpmux-attachment-remove").boundingBox())!;
          expect(remove.width, name).toBeLessThanOrEqual(16);
          expect(remove.height, name).toBeLessThanOrEqual(16);
          // The × sits in the top-right corner, clear of the thumbnail's centre where a drag starts.
          expect(remove.x, name).toBeGreaterThan(box.x + box.width / 2);
          expect(remove.y + remove.height, name).toBeLessThan(box.y + box.height / 2);

          // Press the first thumbnail's centre and drag it past the second's centre.
          const before = await ids(page);
          expect(before.length, name).toBe(2);
          const second = (await page.locator(CHIP).nth(1).locator(".acpmux-attachment-image").boundingBox())!;
          await page.mouse.down();
          await page.mouse.move(second.x + second.width - 4, second.y + second.height / 2, { steps: 12 });
          await page.mouse.up();
          await page
            .waitForFunction(
              ([chip, want]) =>
                [...document.querySelectorAll<HTMLElement>(chip)]
                  .map((each) => each.dataset.inlineAttachment)
                  .join() === want,
              [CHIP, [before[1], before[0]].join()] as const,
              { timeout: 5_000 },
            )
            .catch(() => undefined);
          expect(await ids(page), name).toEqual([before[1], before[0]]);
          // Moved, not copied, and nothing opened the image viewer on the way.
          expect(await page.locator(`${CHIP} img`).count(), name).toBe(2);
          expect(await page.locator(".acpmux-image-viewer, [role='dialog']").count(), name).toBe(0);

          // A press on the × that moves never drags the chip: the order stays, and nothing is copied.
          const flipped = await ids(page);
          const lead = page.locator(CHIP).nth(0);
          await lead.locator(".acpmux-attachment-image").hover();
          const x = (await lead.locator(".acpmux-attachment-remove").boundingBox())!;
          const far = (await page.locator(CHIP).nth(1).locator(".acpmux-attachment-image").boundingBox())!;
          await page.mouse.move(x.x + x.width / 2, x.y + x.height / 2);
          await page.mouse.down();
          await page.mouse.move(far.x + far.width - 4, far.y + far.height / 2, { steps: 12 });
          await page.mouse.up();
          // A drop is handled in the event's own task: two painted frames are past it.
          await page.evaluate(
            () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(undefined)))),
          );
          expect(await ids(page), name).toEqual(flipped);
          expect(await page.locator(`${CHIP} img`).count(), name).toBe(2);

          // The × still removes its attachment.
          const target = page.locator(CHIP).nth(0);
          await target.locator(".acpmux-attachment-image").hover();
          await target.locator(".acpmux-attachment-remove").click();
          expect(await ids(page), name).toEqual([before[0]]);
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
