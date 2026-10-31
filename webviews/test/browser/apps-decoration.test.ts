// l10n-allow-file: public-safe gallery assertions and capture names, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("apps-decoration.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "../..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "pages.apps", { browser, timeoutMs: 120_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["light", "dark"] as const) {
    test(`App Store metadata and fallback icons use quiet surfaces in ${colorScheme}`, async () => {
      const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
      try {
        await page.goto(`${base}${galleryFrame("pages.apps", { variant: "list", colorScheme, reducedMotion: 1 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const card = page
          .locator(".apps-card")
          .filter({ has: page.getByRole("button", { name: "Caffeinate", exact: true }) });
        await card.waitFor();
        const out = process.env.CMUX_APPS_DECORATION_CAPTURE_DIR;
        if (out) {
          await mkdir(out, { recursive: true });
          await card.screenshot({ path: path.join(out, `${colorScheme}.png`) });
        }
        const paint = await card.locator(".apps-badge").evaluateAll((elements) =>
          elements.map((element) => {
            const css = getComputedStyle(element);
            return { text: element.textContent, background: css.backgroundColor, image: css.backgroundImage };
          }),
        );
        expect(paint.map((item) => item.text)).toEqual(["Verified", "Productivity"]);
        for (const item of paint) {
          expect(item.background).toBe("rgba(0, 0, 0, 0)");
          expect(item.image).toBe("none");
        }
        expect(
          await card.locator(".apps-icon-glyph").evaluate((element) => getComputedStyle(element).backgroundImage),
        ).toBe("none");
        await card.getByRole("button", { name: "Install", exact: true }).click();
        await card.getByRole("button", { name: "Remove", exact: true }).waitFor();
        expect(await card.locator(".apps-badge").allTextContents()).toEqual(["Verified", "Productivity", "Installed"]);
        expect(
          await card
            .locator(".apps-badge")
            .last()
            .evaluate((element) => getComputedStyle(element).backgroundColor),
        ).toBe("rgba(0, 0, 0, 0)");
      } finally {
        await page.close();
      }
    });
  }
});
