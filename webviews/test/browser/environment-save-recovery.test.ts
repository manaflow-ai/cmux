// cmux-web-test-timeout: 300
// l10n-allow-file: browser fixture assertions, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "../support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";

await requireBrowserLane("environment-save-recovery.test.ts", async () => {
  const root = path.resolve(import.meta.dir, "../..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch();
    await warmGalleryFrame(vite, "agent-pane.environment-save", { browser });
  }, 120_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const theme of ["light", "dark"]) {
    test(`${theme}: a refused environment save is visible and can be retried`, async () => {
      const page = await browser.newPage({
        viewport: { width: 600, height: 260 },
        reducedMotion: "reduce",
      });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.environment-save", { variant: "refused", colorScheme: theme, reducedMotion: "true" })}`,
        );
        await page.locator('[data-section="environment"]').waitFor();
        expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe(theme);
        expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);
        const save = page.locator('[data-section="environment"] button.acpmux-session-info-link');
        await save.click();
        await page.waitForFunction(() => {
          const button = document.querySelector<HTMLButtonElement>(
            '[data-section="environment"] button.acpmux-session-info-link',
          );
          return button && !button.disabled;
        });
        if (process.env.CMUX_CAPTURE_DIR) {
          await mkdir(process.env.CMUX_CAPTURE_DIR, { recursive: true });
          await page.screenshot({
            path: path.join(process.env.CMUX_CAPTURE_DIR, `environment-save-${theme}.png`),
          });
        }
        expect(await page.locator('[role="alert"]').textContent()).toBe("Couldn’t save: Request failed");
        await save.click();
        await page.waitForFunction(
          () =>
            document.querySelector('[data-section="environment"] button.acpmux-session-info-link')?.textContent ===
            "Saved",
        );
        expect(await save.isDisabled()).toBe(true);
        expect(await page.locator('[role="alert"]').count()).toBe(0);
      } finally {
        await page.close();
      }
    }, 120_000);
  }
});
