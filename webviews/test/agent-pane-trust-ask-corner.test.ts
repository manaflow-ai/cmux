// The folder trust bar over the composer takes the composer card's corner (a layout pass found the
// bar at 8px under a 16px card): both read --acpmux-composer-radius, so whatever corner the card's
// look sets, the bar matches it. Real gallery frames at a wide and a narrow pane.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-trust-ask-corner.test.ts", async () => {
  setDefaultTimeout(240_000);
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
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the trust bar's corner is the composer card's", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const found: string[] = [];
    for (const width of [1100, 420]) {
      const page = await browser!.newPage({ viewport: { width, height: 760 } });
      await page.goto(
        `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.bottom-stack&variant=trust-permission-queue`,
      );
      // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
      await page.locator(".acpmux-trust-ask").first().waitFor({ timeout: 90_000 });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 30_000,
      });
      const corners = await page.evaluate(() => ({
        bar: getComputedStyle(document.querySelector(".acpmux-trust-ask")!).borderTopLeftRadius,
        card: getComputedStyle(document.querySelector(".acpmux-composer-box")!).borderTopLeftRadius,
      }));
      await page.close();
      if (corners.bar !== corners.card) found.push(`@${width}: bar ${corners.bar}, card ${corners.card}`);
    }
    expect(found).toEqual([]);
  });
});
