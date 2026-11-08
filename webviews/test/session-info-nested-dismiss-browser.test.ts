// l10n-allow-file: the synthetic gallery supplies the labels and pull request.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-nested-dismiss-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.session-info-dismiss";
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "panel" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const inDialog of [false, true]) {
    for (const outside of [false, true]) {
      for (const repository of [false, true]) {
        test(`${inDialog ? "in a dialog: " : ""}a press ${outside ? "outside" : "inside"} Session Info dismisses only its nested ${repository ? "repository picker" : "PR menu"}`, async () => {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          const page = await browser!.newPage({ viewport: { width: 900, height: 420 }, deviceScaleFactor: 2 });
          try {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(entry, { variant: inDialog ? "dialog-panel" : "panel" })}`,
            );
            const panel = page.locator("aside.acpmux-session-info");
            await panel.waitFor();
            const popup = repository ? ".acpmux-cloud-repository-picker" : '[role="menu"]';
            await page.locator(repository ? "[data-repository-trigger]" : ".acpmux-session-info-pr__more").click();
            await page.locator(popup).waitFor();
            if (process.env.FAST_CHECKS_OUT) {
              await page.screenshot({
                path: path.join(
                  process.env.FAST_CHECKS_OUT,
                  `session-info-nested-${inDialog ? "dialog" : "panel"}.png`,
                ),
              });
            }
            // Exercise the real portal, rather than a menu rendered inside the parent's DOM.
            expect(await panel.locator(popup).count()).toBe(0);
            const press = page.locator(outside ? "[data-outside-panel]" : "[data-inside-panel]");
            // The repository picker intentionally covers the panel's button. Press a visible
            // point at the panel's upper edge for the inside case so the event is a real browser
            // pointer event while remaining outside the child portal.
            if (outside) await press.click();
            else {
              const box = await panel.boundingBox();
              expect(box).not.toBeNull();
              await page.mouse.click(box!.x + 6, box!.y + 6);
            }
            await page.locator(popup).waitFor({ state: "detached" });
            expect(await panel.count()).toBe(1);
            // Once its child is gone, the next outside press dismisses the parent normally.
            await page.locator("[data-outside-panel]").click();
            await panel.waitFor({ state: "detached" });
          } finally {
            await page.close();
          }
        });
      }
    }
  }
});
