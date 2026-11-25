// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("browser-preview-proof-browser.test.ts", async () => {
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.browser-preview-proof", {
      browser,
      params: { variant: "with-console-error" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["with-console-error", "clean"] as const)
    for (const colorScheme of ["dark", "light"] as const)
      test(`preview proof renders its screenshot and report (${variant}, ${colorScheme})`, async () => {
        const page = await browser!.newPage({
          viewport: { width: 760, height: 600 },
          deviceScaleFactor: 2,
          colorScheme,
        });
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.message));
        try {
          const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
          await page.goto(
            base + galleryFrame("agent-pane.browser-preview-proof", { variant, colorScheme, width: 760, height: 600 }),
          );
          await page.waitForFunction(() =>
            ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          );
          expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
          // Closed, the call is one line with its screenshot small at its edge; opened, the screenshot
          // shows over the report (Lucas, 2026-11-11: a run of captures stays a list of lines).
          await page.locator(".cv-tool-visual img").waitFor();
          expect(await page.locator(".cv-tool-images img").count()).toBe(0);
          await page.locator('[data-tool-id="gallery-browser-proof"]').click();
          const image = page.locator(".cv-tool-images img");
          await image.waitFor();
          await image.evaluate((element) => (element as HTMLImageElement).decode());
          expect(await image.count()).toBe(1);
          expect(await image.evaluate((element) => (element as HTMLImageElement).naturalWidth)).toBe(640);
          await page.getByText('"consoleErrors"', { exact: false }).first().waitFor();
          await page.waitForFunction(() => {
            const fold = document.querySelector(".cv-fold");
            return (
              fold &&
              getComputedStyle(fold).opacity === "1" &&
              fold.getBoundingClientRect().height >= fold.scrollHeight - 1
            );
          });
          const report = await page.locator("body").innerText();
          expect(report).toContain("http://127.0.0.1:5173/");
          expect(report).toContain('"pageErrors": []');
          if (variant === "with-console-error") expect(report).toContain("Preview reported a hydration error");
          else expect(report).toContain('"consoleErrors": []');
          const captures = process.env.CMUX_BROWSER_PROOF_CAPTURE_DIR;
          if (captures) {
            await mkdir(captures, { recursive: true });
            await page.screenshot({
              path: path.join(captures, `browser-preview-proof-${variant}-${colorScheme}.png`),
              animations: "disabled",
            });
          }
          expect(errors).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
