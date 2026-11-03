// l10n-allow-file: synthetic Home gallery interactions and assertions.
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("home-chief-work-integration-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "pages.home-channels";
  const variant = "run";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const openThread = async (page: Page) => {
    const message = page.locator(".lg-main .hc-msg").filter({ hasText: "Start all three." }).first();
    await message.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Reply in Thread", exact: true }).click();
    await page.locator(".lg-sheet .hc-composer").waitFor();
  };
  for (const [width, colorScheme] of [
    [390, "dark"],
    [1600, "light"],
  ] as const) {
    test(`${width}px: the real Chief header opens work and Escape closes it`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 844 }, deviceScaleFactor: 2 });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height: 844, colorScheme })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const chief = page.locator('[data-list-row="c-chief"]');
        if (await chief.isVisible()) await chief.click();
        const toggle = page.getByRole("button", { name: "Work", exact: true });
        await toggle.waitFor();
        if (width === 390) {
          const target = (await toggle.boundingBox())!;
          expect(target.width).toBeGreaterThanOrEqual(44);
          expect(target.height).toBeGreaterThanOrEqual(44);
        }
        await toggle.click();
        const panel = page.getByRole("complementary", { name: "Work", exact: true });
        await panel.getByText("Build a hello page", { exact: true }).waitFor();
        await panel.getByText("Review the finished preview", { exact: true }).waitFor();
        await panel.getByText("Background commands", { exact: true }).waitFor();
        expect(await toggle.getAttribute("aria-pressed")).toBe("true");
        expect(await panel.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true);
        if (width === 1600) {
          const composer = (await page.locator(".lg-main-compose").boundingBox())!;
          const sheet = (await panel.boundingBox())!;
          expect(composer.x + composer.width).toBeLessThanOrEqual(sheet.x + 1);
        }
        if (process.env.FAST_CHECKS_OUT) {
          await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
          await page.screenshot({
            path: path.join(process.env.FAST_CHECKS_OUT, `chief-work-home-${width}-${colorScheme}.png`),
          });
        }
        // The header keeps focus when its button opens Work. Escape must close the sheet
        // before the narrow page handles a later Escape by returning to the list.
        await toggle.focus();
        await page.keyboard.press("Escape");
        await panel.waitFor({ state: "hidden" });
        expect(await toggle.getAttribute("aria-pressed")).toBe("false");
        if (width === 1600) {
          await openThread(page);
          await toggle.click();
          await panel.waitFor();
          expect(await page.locator(".lg-sheet").count()).toBe(1);
          expect(await page.locator(".lg-sheet .hc-composer").count()).toBe(0);
          await openThread(page);
          await panel.waitFor({ state: "hidden" });
          expect(await page.locator(".lg-sheet").count()).toBe(1);
        }
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
