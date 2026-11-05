// cmux-web-test-timeout: 600
// l10n-allow-file: browser assertions and synthetic gallery fixtures.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("slack-gallery-browser.test.ts", async () => {
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const out = process.env.FAST_CHECKS_OUT;
  beforeAll(async () => {
    vite = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "settings.slack-connection", { browser, params: { variant: "disconnected" } });
    await warmGalleryFrame(vite, "pages.home-channels", { browser, params: { variant: "slack-thread" } });
    if (out) await mkdir(out, { recursive: true });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["light", "dark"] as const) {
    for (const variant of ["disconnected", "connecting", "connected", "error"]) {
      test(`Slack connection ${variant}, ${colorScheme}`, async () => {
        const page = await browser.newPage({
          viewport: { width: 640, height: 260 },
          deviceScaleFactor: 2,
          colorScheme,
        });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("settings.slack-connection", { variant, colorScheme })}`,
          );
          const row = page.locator('[data-card="slack-connection"]');
          await row.waitFor();
          expect(await row.locator(".row-title").textContent()).toBe("Slack");
          expect(await row.locator("button").isDisabled()).toBe(variant === "connecting");
          expect(await row.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true);
          if (variant === "connected") expect(await row.textContent()).toContain("Example workspace");
          if (variant === "error") expect(await row.locator('[role="alert"]').isVisible()).toBe(true);
          if (out) await page.screenshot({ path: path.join(out, `slack-${variant}-${colorScheme}.png`) });
        } finally {
          await page.close();
        }
      }, 120_000);
    }
    test(`Slack thread source, ${colorScheme}`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 620 }, deviceScaleFactor: 2, colorScheme });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("pages.home-channels", { variant: "slack-thread", colorScheme })}`,
        );
        const link = page.locator("a.hc-slack-source").first();
        await link.waitFor();
        expect(await link.textContent()).toContain("Slack · #");
        expect(await link.getAttribute("href")).toMatch(/^https:\/\/[^/]+\.slack\.com\//);
        if (out) await page.screenshot({ path: path.join(out, `slack-thread-${colorScheme}.png`) });
      } finally {
        await page.close();
      }
    }, 120_000);
  }
});
