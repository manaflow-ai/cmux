// l10n-allow-file: synthetic lane names and messages, never private transcripts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("received-message-layout-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.message-presentation";
  let vite: ViteDevServer;
  let browser: Browser;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const open = async (width: number, colorScheme: "dark" | "light"): Promise<Page> => {
    const { port } = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width, height: 760 }, colorScheme });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "compact", colorScheme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    if (width === 360)
      await page.evaluate(() => {
        document.documentElement.style.zoom = "1.25";
      });
    return page;
  };

  for (const colorScheme of ["dark", "light"] as const) {
    for (const width of [760, 360]) {
      test(`received and queued strips keep text clear of actions at ${width}px in ${colorScheme}`, async () => {
        const page = await open(width, colorScheme);
        const queued = page.locator("[data-queued-message]").first();
        const received = page.locator('[data-row-id="presentation-received"] .cv-received');
        expect(await received.locator(".cv-received__toggle").getAttribute("aria-expanded")).toBe("false");
        expect(await received.locator(".cv-received__body").count()).toBe(0);
        const strip = await received.evaluate((row) => {
          const icon = row.querySelector(".cv-received__icon")!.getBoundingClientRect();
          const sender = row.querySelector(".cv-received__name")!.getBoundingClientRect();
          const preview = row.querySelector(".cv-received__preview")!.getBoundingClientRect();
          const toggle = row.querySelector(".cv-received__toggle")!.getBoundingClientRect();
          return {
            iconCenter: icon.top + icon.height / 2,
            senderCenter: sender.top + sender.height / 2,
            previewWidth: preview.width,
            toggleWidth: toggle.width,
          };
        });
        expect(Math.abs(strip.iconCenter - strip.senderCenter)).toBeLessThanOrEqual(1);
        expect(strip.previewWidth).toBeGreaterThan(0);
        expect(strip.toggleWidth).toBeGreaterThanOrEqual(20);
        expect(await queued.locator(".cv-received__queued").textContent()).toBe("Read after this turn");
        await queued.hover();
        await page.waitForFunction(() => {
          const actions = document.querySelector("[data-queued-message] .cv-received__queued-actions");
          return actions && getComputedStyle(actions).opacity === "1";
        });
        const layout = await queued.evaluate((row) => {
          const line = row.querySelector<HTMLElement>(".cv-received__line")!;
          const status = row.querySelector<HTMLElement>(".cv-received__queued")!;
          const actions = row.querySelector<HTMLElement>(".cv-received__queued-actions")!;
          const lineBox = line.getBoundingClientRect();
          const statusBox = status.getBoundingClientRect();
          const actionsBox = actions.getBoundingClientRect();
          return {
            overlap:
              Math.max(0, Math.min(statusBox.right, actionsBox.right) - Math.max(statusBox.left, actionsBox.left)) *
              Math.max(0, Math.min(statusBox.bottom, actionsBox.bottom) - Math.max(statusBox.top, actionsBox.top)),
            overhang: actionsBox.right - lineBox.right,
            captionWidth: statusBox.width,
            actionWidth: actionsBox.width,
            actionVisibility: getComputedStyle(actions).opacity,
          };
        });
        expect(layout.overlap).toBeLessThanOrEqual(0.5);
        expect(layout.overhang).toBeLessThanOrEqual(0.5);
        expect(layout.captionWidth).toBeGreaterThan(20);
        expect(layout.actionWidth).toBeGreaterThan(30);
        expect(layout.actionVisibility).toBe("1");
        // These are the queued row's own actions; the shared RowFrame copy is removed by #26096.
        expect(await queued.locator('.cv-received__queued-actions button[aria-label="Copy"]').count()).toBe(1);
        await received.locator(".cv-received__toggle").click();
        await received.locator(".cv-received__body").waitFor();
        expect(await received.locator(".cv-received__text strong").textContent()).toBe("Review passed.");
        expect(await received.locator(".cv-received__text li").count()).toBe(2);
        expect(
          await received.locator(".cv-received__body").evaluate((body) => getComputedStyle(body).backgroundColor),
        ).toBe("rgba(0, 0, 0, 0)");
        await page.close();
      });
    }
  }
});
