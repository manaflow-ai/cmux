// cmux-web-test-timeout: 300
// l10n-allow-file: gallery fixture labels, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-hover-gallery.test.ts", async () => {
  const entry = "home-channels.transcript-hover";
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
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "channel" } });
  }, 120_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["channel", "messages", "run", "run-link"])
    for (const colorScheme of ["light", "dark"] as const)
      test(`${variant} hover in ${colorScheme}`, async () => {
        const page = await browser.newPage({ viewport: { width: 640, height: 360 }, colorScheme });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}` + galleryFrame(entry, { variant, colorScheme }));
          await page.waitForFunction(() =>
            ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          );
          expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
          // Leave the gallery's scripted hover and enter with a real browser pointer.
          await page.mouse.move(2, 2);
          const link = variant === "run-link";
          await page.locator(link ? ".lg-run-links a" : "time.cv-time-hover").hover();
          const popup = page.locator(link ? ".cv-link-preview" : ".ui-tooltip");
          await popup.waitFor({ timeout: 3000 });
          expect(await popup.textContent()).not.toBe("");
          if (link) expect(await page.locator(".lg-run-links a").getAttribute("target")).toBe("_blank");
          if (process.env.FAST_CHECKS_OUT)
            await page.screenshot({ path: `${process.env.FAST_CHECKS_OUT}/${variant}-${colorScheme}.png` });
          if (link) {
            // Channels has no agent browser.openIn host. Both preview actions must use the
            // original anchor's navigation, including its new browsing context.
            await page
              .context()
              .route("https://example.com/**", (route) =>
                route.fulfill({ contentType: "text/html", body: "Reference opened" }),
              );
            for (const action of ["open", "menu"]) {
              await page.locator(".lg-run-links a").hover();
              await popup.waitFor({ timeout: 3000 });
              if (action === "menu") await popup.locator(".acpmux-open-in").click();
              const [opened] = await Promise.all([
                page.waitForEvent("popup", { timeout: 3000 }),
                action === "open"
                  ? popup.locator(".cv-link-preview__open").click()
                  : page.getByRole("menuitem").first().click(),
              ]);
              await opened.waitForLoadState();
              expect(opened.url()).toBe("https://example.com/reference");
              await opened.close();
            }
          }
        } catch (error) {
          if (process.env.FAST_CHECKS_OUT)
            await page.screenshot({ path: `${process.env.FAST_CHECKS_OUT}/${variant}-${colorScheme}-failed.png` });
          throw error;
        } finally {
          await page.close();
        }
      }, 60_000);
});
