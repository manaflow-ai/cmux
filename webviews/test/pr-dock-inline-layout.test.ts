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

  for (const layout of ["above", "beside", "below"])
    for (const width of [760, 320])
      test(`${layout}, ${width}px: expanded chips clear Show more and the disclosure`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 420 } });
        try {
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: `inline-${layout}-show-more`, width })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const chips = page.locator(".acpmux-pr-dock__chip");
          await chips.first().waitFor();
          // Real boxes, including the received line immediately above the dock.
          const geometry = await page.evaluate(() => {
            const box = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
            // Received messages are one-line strips until explicitly opened; the PR chips must
            // clear that strip as well as the disclosure row.
            const receivedLine = box(".cv-received__line");
            const row = box(".acpmux-pr-dock__compact");
            const dock = box(".acpmux-pr-dock");
            const overlaps = (a: DOMRect, b: DOMRect) =>
              a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
            return [...document.querySelectorAll(".acpmux-pr-dock__chip")].map((chip) => {
              const rect = chip.getBoundingClientRect();
              return {
                card: overlaps(rect, receivedLine),
                disclosure: overlaps(rect, row),
                contained: rect.top >= dock.top && rect.bottom <= dock.bottom,
              };
            });
          });
          if (process.env.CMUX_PR_DOCK_CAPTURE)
            await page.screenshot({ path: `${process.env.CMUX_PR_DOCK_CAPTURE}/${layout}-${width}.png` });
          expect(geometry).toHaveLength(2);
          for (const chip of geometry) expect(chip).toEqual({ card: false, disclosure: false, contained: true });
          const disclosure = page.locator(".acpmux-pr-dock__disclosure");
          expect(await disclosure.getAttribute("aria-expanded")).toBe("true");
          const listId = await disclosure.getAttribute("aria-controls");
          expect(await page.locator(`[id="${listId}"] .acpmux-pr-dock__chip`).count()).toBe(2);
          await page.keyboard.press("Escape");
          expect(await disclosure.getAttribute("aria-expanded")).toBe("false");
          expect(await disclosure.evaluate((element) => element === document.activeElement)).toBe(true);
          expect(await chips.count()).toBe(0);
        } finally {
          await page.close();
        }
      });
});
