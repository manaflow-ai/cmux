// l10n-allow-file: public-safe gallery state assertions.
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chief-work-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "pages.home-chief-work", {
      browser,
      params: { variant: "phone" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const [variant, width, height, scheme] of [
    ["phone", 390, 844, "light"],
    ["phone", 390, 844, "dark"],
    ["active", 1280, 900, "light"],
    ["empty", 390, 844, "light"],
    ["error", 390, 844, "dark"],
    ["loading", 390, 844, "light"],
  ] as const) {
    test(`${variant} ${scheme}: truthful work state fits the pane`, async () => {
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame("pages.home-chief-work", { variant, width, height, colorScheme: scheme }));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const panel = page.getByRole("complementary", { name: "Work", exact: true });
        await panel.waitFor();
        expect(await panel.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true);
        const refresh = page.getByRole("button", { name: "Refresh", exact: true });
        expect((await refresh.boundingBox())!.height).toBeGreaterThanOrEqual(44);
        if (variant === "phone" || variant === "active") {
          await page.getByText("Design the hello page", { exact: true }).waitFor();
          const completed = page.getByText("Check the page", { exact: true });
          expect(await completed.isVisible()).toBe(false);
          await page.locator(".hc-chief-work__finished > summary").click();
          await completed.waitFor({ state: "visible" });
          await page.getByText("Build the hello page", { exact: true }).click();
          await page.getByText("bun run build", { exact: true }).waitFor({ state: "visible" });
        } else if (variant === "empty") await page.getByText("No background work", { exact: true }).waitFor();
        else {
          expect(await page.getByText("No background work", { exact: true }).count()).toBe(0);
          if (variant === "loading") expect(await refresh.isDisabled()).toBe(true);
        }
        if (process.env.FAST_CHECKS_OUT) {
          await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
          await page.screenshot({
            path: path.join(process.env.FAST_CHECKS_OUT, `chief-work-${variant}-${scheme}.png`),
          });
        }
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
