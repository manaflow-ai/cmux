// cmux-web-test-timeout: 600
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("menu-health-papercuts.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const scenes = [
    ["agent-pane.changes-git-actions", "include-new", 480, 520],
    ["agent-pane.changes-git-actions", "keyboard", 480, 520],
    ["pages.settings", "font-picker", 1000, 760],
    ["viewer-empty.path-picker", "rtl", 620, 620],
  ] as const;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const [entry, variant] of scenes) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [entry, variant, width, height] of scenes) {
    test(`${entry}#${variant}: scope stays still and menu geometry follows its content`, async () => {
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        if (entry === "agent-pane.changes-git-actions") {
          const steps = await page.evaluate(() =>
            window.cmuxGalleryPlayReport!.steps.map((step) => ({
              step: step.step,
              shift: Math.max(step.layoutShift, step.boxShift ?? 0),
            })),
          );
          const change = steps.find(
            (step) => step.step === (variant === "keyboard" ? "press ArrowRight" : 'click radio "All"'),
          );
          expect(change).toBeDefined();
          expect(change!.shift).toBeLessThanOrEqual(0.0005);
          if (variant === "include-new") expect(await page.locator(".acpmux-git-new-files li").count()).toBe(2);
        } else {
          const violations = await page.evaluate(() =>
            (window as unknown as { cmuxGalleryInvariants(): { rule: string; key: string }[] }).cmuxGalleryInvariants(),
          );
          const rule = entry === "pages.settings" ? "menu-fit" : "menu-label";
          expect(violations.filter((violation) => violation.rule === rule)).toEqual([]);
          if (entry === "pages.settings") {
            const bounds = await page.locator(".font-picker-panel").boundingBox();
            expect(bounds).not.toBeNull();
            expect(bounds!.x).toBeGreaterThanOrEqual(0);
            expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
          }
        }
        if (process.env.FAST_CHECKS_OUT)
          await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `${entry}-${variant}.png`) });
      } finally {
        await page.close();
      }
    });
  }
});
