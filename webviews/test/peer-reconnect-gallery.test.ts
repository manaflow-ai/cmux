// l10n-allow-file: gallery fixture text, not shipped UI.
// cmux-web-test-timeout: 300
// Capture the actual composer row at first detection and prolonged outages. The same
// harness records the old row so the before/after visibility receipt is reproducible.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("peer-reconnect-gallery.test.ts", async () => {
  setDefaultTimeout(240_000);
  const entry = "agent-pane.machine-link";
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT || path.join(webviews, "artifacts", "peer-reconnect");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const measurements: unknown[] = [];

  beforeAll(async () => {
    mkdirSync(out, { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "outage-1s" } });
  });
  afterAll(async () => {
    writeFileSync(path.join(out, "reconnect-visibility.json"), JSON.stringify(measurements, null, 2));
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["before", "outage-1s", "outage-3s", "outage-10s", "outage-120s", "outage-long-name"])
    for (const width of [360, 760])
      test(`${variant} at ${width}px`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 140 }, deviceScaleFactor: 2 });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme: "Apple System Colors" })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.evaluate(() => document.fonts.ready);
          const row = page.locator("[data-peer-reconnecting]");
          if (variant === "before") expect(await row.count()).toBe(0);
          else {
            await row.waitFor({ state: "visible" });
            const seconds = variant === "outage-long-name" ? "3" : variant.slice(7, -1);
            expect(await row.textContent()).toContain(` · ${seconds} s`);
            expect(await page.locator(".acpmux-machine-link").getAttribute("data-quiet")).toBeNull();
          }
          measurements.push({ variant, width, text: await row.allTextContents() });
          await page.emulateMedia({ reducedMotion: "reduce" });
          await page.screenshot({ path: path.join(out, `${variant}-${width}.png`) });
        } finally {
          await page.close();
        }
      });
});
