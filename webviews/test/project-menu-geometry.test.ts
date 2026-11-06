// Project geometry is measured with the other menu families in checkmark-alignment.test.ts.
// Keep the project-specific affordance check behavioral: a current project still exposes its
// badge and path when its check moves to the shared leading state column.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("project-menu-geometry.test.ts", async () => {
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.project-chooser", { browser, params: { variant: "open-current" } });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test("project badge, primary name and path retain their shared columns", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 700 } });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.project-chooser", { variant: "open-current" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const rows = await page
        .locator(".acpmux-project-menu .acpmux-menu-item:has(.acpmux-project-badge)")
        .evaluateAll((items) =>
          items.map((item) => {
            const menu = item.closest(".acpmux-project-menu")!.getBoundingClientRect();
            const badge = item.querySelector(".acpmux-project-badge")!.getBoundingClientRect();
            const label = item.querySelector(".acpmux-menu-label")!.getBoundingClientRect();
            const path = item.querySelector(".acpmux-menu-description")!;
            return {
              lead: badge.left - menu.left,
              box: badge.width,
              text: label.left - menu.left,
              secondary: path.getBoundingClientRect().left - menu.left,
              path: path.getAttribute("data-path"),
            };
          }),
        );
      expect(rows.length).toBeGreaterThan(0);
      for (const row of rows) {
        expect(row.lead).toBe(22);
        expect(row.box).toBe(14);
        expect(row.text).toBe(42);
        expect(row.secondary).toBe(row.text);
        expect(row.path).toBeTruthy();
      }
    } finally {
      await page.close();
    }
  }, 120_000);
});
