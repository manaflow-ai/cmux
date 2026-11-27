// l10n-allow-file: gallery fixture labels are test data.
// A bounded Chromium readback for the tripwire gallery: all-green, one-red and never-run states,
// plus the three quiet looks. CI can retain the captures through FAST_CHECKS_OUT.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("tripwires.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.tripwire-status";

  beforeAll(async () => {
    vite = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const variants = [
    ["green-dots", 0],
    ["red-dots", 1],
    ["never-run", 3],
    ["underline", 1],
    ["rows", 1],
  ] as const;
  for (const [variant, unresolved] of variants) {
    test(`tripwire gallery ${variant} keeps the fixed header and verdict evidence`, async () => {
      const page = await browser.newPage({ viewport: { width: 680, height: 220 }, reducedMotion: "reduce" });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 680, height: 220 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const status = page.locator("[data-tripwire-count]");
        await status.waitFor();
        expect(await status.getAttribute("data-tripwire-count")).toBe("3");
        expect(await status.getAttribute("data-tripwire-total")).toBe("3");
        expect(await status.getAttribute("data-tripwire-unresolved")).toBe(String(unresolved));
        expect(await status.getAttribute("data-tripwire-complete")).toBe(unresolved === 0 ? "true" : "false");
        expect(await status.locator('[data-tripwire-verdict="backed"]').count()).toBe(3 - unresolved);
        expect(await status.locator('[data-tripwire-verdict="failed"]').count()).toBe(unresolved === 1 ? 1 : 0);
        expect(await status.locator('[data-tripwire-verdict="none"]').count()).toBe(unresolved === 3 ? 3 : 0);
        expect(await status.locator(".acpmux-tripwire").count()).toBe(3);
        const box = await status.boundingBox();
        expect(box?.height).toBeLessThanOrEqual(90);
        const overflow = await status.evaluate((node) => node.scrollHeight - node.clientHeight);
        expect(overflow).toBeLessThanOrEqual(1);
        const output = process.env.FAST_CHECKS_OUT;
        if (output) {
          await fs.mkdir(output, { recursive: true });
          await page.screenshot({ path: path.join(output, `tripwires-${variant}.png`), fullPage: true });
        }
      } finally {
        await page.close();
      }
    });
  }
});
