// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
// Leo 2026-10-30, on Settings > Updates: "look for wastage". Real Chromium lays out the settings
// gallery's Updates page and holds it to design/settings.md: a group title never repeats its page's
// title (the page read "Updates", then "Updates" again over its first group, then "Updates:
// Advanced"). With FAST_CHECKS_OUT set it writes 2x light and dark stills of the page's top and of
// its Advanced group.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("settings-group-titles-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  } catch {
    console.warn("settings-group-titles: chromium cannot launch here; skipping");
    describe.skip("settings group titles", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "pages.settings", { params: { variant: "updates" } });
    if (out) await mkdir(out, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["light", "dark"] as const) {
    test(`Updates draws its title once and its advanced group as Advanced (${colorScheme})`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({
        viewport: { width: 900, height: 640 },
        deviceScaleFactor: 2,
        reducedMotion: "reduce",
      });
      try {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant: "updates", colorScheme, width: 900, height: 640 })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
        await page.waitForSelector('[data-section="updates"] [data-row-key="updates.channel"]');
        const drawn = await page.evaluate(() => {
          const section = document.querySelector('[data-section="updates"]')!;
          const visible = (el: Element) => {
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          };
          return {
            page: section.querySelector(".section-title")?.textContent ?? "",
            groups: [...section.querySelectorAll("section.group[data-group] .group-title")]
              .filter(visible)
              .map((title) => title.textContent ?? ""),
          };
        });
        // The stills first, so a red run still shows what it drew.
        if (out) {
          await page.screenshot({ path: path.join(out, `settings-updates-top-${colorScheme}-chromium.png`) });
          await page.locator('[data-row-key="updates.idleInstallMaxWaitSeconds"]').scrollIntoViewIfNeeded();
          await page.screenshot({ path: path.join(out, `settings-updates-advanced-${colorScheme}-chromium.png`) });
        }
        expect(drawn.page).toBe("Updates");
        expect(drawn.groups).toEqual(["Advanced"]);
      } finally {
        await page.close();
      }
    });
  }
});
