// cmux-web-test-timeout: 1200
// l10n-allow-file: gallery browser assertions and capture filenames.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cloud-menu-highlight-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const scenes = [
    ["agent-pane.composer-context", "folder-menu", ".acpmux-folder-popover", true],
    ["agent-pane.composer-context", "folder-menu-hover", ".acpmux-folder-popover", false],
    ["agent-pane.composer-context", "folder-menu-keyboard", ".acpmux-folder-popover", false],
    ["agent-pane.composer", "access-menu", ".acpmux-access-menu", false],
    ["agent-pane.saved-environment-panel", "ssh-host-hover", ".acpmux-env-host-menu", false],
    ["agent-pane.suggested-tasks", "options-model-menu", ".acpmux-task-menu", false],
  ] as const;

  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    for (const [entry, variant] of scenes) await warmGalleryFrame(vite, entry, { params: { variant } });
    browser = await chromium.launch({ headless: true });
    if (process.env.FAST_CHECKS_OUT) await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
  }, 600_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["light", "dark"] as const) {
    for (const [entry, variant, selector, automatic] of scenes) {
      test(`${variant}: ${colorScheme} selection and navigation stay distinct`, async () => {
        const page = await browser.newPage({
          viewport: { width: 620, height: 480 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme, width: 620, height: 480 })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
          expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
          const report = await page.evaluate(() =>
            JSON.stringify((window as unknown as { cmuxGalleryPlayReport: unknown }).cmuxGalleryPlayReport),
          );
          expect(playFailures(report)).toEqual([]);
          await page.locator(selector).waitFor({ state: "visible" });
          if (process.env.FAST_CHECKS_OUT)
            await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `${variant}-${colorScheme}.png`) });
          const paints = await page.locator(selector).evaluate((popup) => {
            const probe = document.createElement("span");
            probe.style.background = "var(--acpmux-menu-hover)";
            popup.append(probe);
            const neutral = getComputedStyle(probe).backgroundColor;
            probe.remove();
            return {
              neutral,
              selectedCount: popup.querySelectorAll('[aria-checked="true"], [data-current]').length,
              highlighted: [...popup.querySelectorAll("[data-highlighted]")].map((row) => ({
                background: getComputedStyle(row).backgroundColor,
                shadow: getComputedStyle(row).boxShadow,
              })),
              selected: [...popup.querySelectorAll('[aria-checked="true"], [data-current]')]
                .map((row) => row.closest('[role="option"], [role="menuitemradio"], [role="menuitemcheckbox"]'))
                .filter((row): row is Element => row !== null && !row.hasAttribute("data-highlighted"))
                .map((row) => getComputedStyle(row).backgroundColor),
            };
          });
          expect(paints.selectedCount).toBeGreaterThan(0);
          if (!automatic) expect(paints.highlighted.length).toBeGreaterThan(0);
          for (const row of paints.highlighted) {
            expect(row.background).toBe(automatic ? "rgba(0, 0, 0, 0)" : paints.neutral);
            expect(row.shadow).toBe("none");
          }
          for (const background of paints.selected) expect(background).toBe("rgba(0, 0, 0, 0)");
        } finally {
          await page.close();
        }
      });
    }
  }
});
