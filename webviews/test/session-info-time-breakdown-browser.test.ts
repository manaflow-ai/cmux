// l10n-allow-file: browser fixture labels and turn ids.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-time-breakdown-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const route = "/test/browser/session-info-time-breakdown.html";
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, route);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const look of ["stacked", "lanes", "totals"]) {
    test(`${look}: bounded navigation, partial usage and narrow layout`, async () => {
      const { port } = vite.httpServer!.address() as { port: number };
      const page = await browser.newPage({ viewport: { width: 360, height: 640 }, reducedMotion: "reduce" });
      try {
        await page.goto(`http://127.0.0.1:${port}${route}?look=${look}`);
        await page.locator(".acpmux-time-breakdown").waitFor();
        expect(await page.locator(".acpmux-time-breakdown").textContent()).toContain("At least");
        expect(await page.locator(".acpmux-time-breakdown__span").count()).toBeLessThanOrEqual(24);
        const selector =
          look === "totals" ? ".acpmux-time-breakdown__total-row:not(:disabled)" : ".acpmux-time-breakdown__span";
        await page.locator(selector).first().click();
        await page.waitForFunction(() => document.body.hasAttribute("data-revealed-turn"));
        const first = await page.locator("body").getAttribute("data-revealed-turn");
        await page.getByRole("button", { name: "Older", exact: true }).click();
        await page.locator(selector).first().click();
        await page.waitForFunction((old) => document.body.getAttribute("data-revealed-turn") !== old, first);
        expect(await page.locator(".acpmux-time-breakdown__span").count()).toBeLessThanOrEqual(24);
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
        if (process.env.FAST_CHECKS_OUT) {
          await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
          await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `time-breakdown-${look}.png`) });
        }
      } finally {
        await page.close();
      }
    });
  }
});
