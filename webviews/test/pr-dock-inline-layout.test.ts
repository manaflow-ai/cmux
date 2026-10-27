// l10n-allow-file: synthetic gallery fixture and test labels, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { createServer, type ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("pr-dock-inline-layout.test.ts", () => {
  setDefaultTimeout(120_000);
  let browser: Browser;
  let vite: ViteDevServer;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "agent-pane.pr-dock", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [760, 320])
    test(`${width}px: PR pills share the action row and overflow never moves the transcript`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 420 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: "compact-count", width })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const dock = page.locator(".acpmux-pr-dock");
        await dock.waitFor();
        if (process.env.CMUX_PR_DOCK_CAPTURE)
          await page.screenshot({ path: `${process.env.CMUX_PR_DOCK_CAPTURE}/closed-${width}.png` });
        expect(await dock.evaluate((node) => !!node.closest(".cv-turn-actions"))).toBe(true);
        expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBeGreaterThan(0);
        expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBeLessThanOrEqual(2);
        expect(await dock.locator(".acpmux-pr-dock__dismiss").count()).toBe(0);
        const geometry = () =>
          page.evaluate(() =>
            [...document.querySelectorAll(".acpmux-row, .acpmux-composer")].map((node) => {
              const box = node.getBoundingClientRect();
              return { y: box.y, height: box.height };
            }),
          );
        const before = await geometry();
        const more = dock.locator(".acpmux-pr-dock__more");
        await more.click();
        await page.locator(".acpmux-pr-dock__popover").waitFor();
        expect(await geometry()).toEqual(before);
        expect(await page.locator(".acpmux-pr-dock__popover .acpmux-pr-dock__bar").count()).toBe(
          4 - (await dock.locator(".acpmux-pr-dock__bar").count()),
        );
        if (process.env.CMUX_PR_DOCK_CAPTURE)
          await page.screenshot({ path: `${process.env.CMUX_PR_DOCK_CAPTURE}/open-${width}.png` });
        await page.keyboard.press("Escape");
        expect(await more.getAttribute("aria-expanded")).toBe("false");
        expect(await more.evaluate((node) => node === document.activeElement)).toBe(true);
        expect(await geometry()).toEqual(before);
      } finally {
        await page.close();
      }
    });
});
