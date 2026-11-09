// cmux-web-test-timeout: 240
// The Cloud Environment chip's drop-up never covers the composer (Leo, 2026-11-07: "drop up, that
// is, because you don't want to hide the composer"), and the chip opening or closing moves nothing
// before it in the strip. Measured in real Chromium on the gallery entry
// agent-pane.cloud-environment-chip: a chat's composer at the bottom of the pane and the New Tab
// page's in the top half, each with the drop-up open, every row style.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("cloud-environment-chip-geometry.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("cloud-environment-chip-geometry: skipping (run `bunx playwright install chromium`)");
    describe.skip("cloud environment chip geometry", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.cloud-environment-chip";
  const ENTRY_PATH = "src/agent-session/acpmux/CloudEnvironmentChip.gallery.tsx";
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${ENTRY}&entryPath=${ENTRY_PATH}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const file of [ENTRY_PATH, "src/gallery/frame/component.tsx"])
      if ((await warmViteServer(vite, `/gallery/${file}`)) === 0)
        throw new Error(`warmViteServer: ${file} imports nothing; is it served?`);
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 620, height: 420 } });
    await warm.goto(stageURL("cloud-auto"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width = 620, height = 420): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  const openDropUp = async (page: Page) => {
    await page.click('.acpmux-cloud-env-slot[data-shown="true"] button');
    await page.waitForSelector(".acpmux-cloud-env-menu [role='menuitemradio']");
    // The popup's own open transition settles before it is measured.
    await page.waitForFunction(() => {
      const menu = document.querySelector(".acpmux-cloud-env-menu");
      return menu && getComputedStyle(menu).opacity === "1";
    });
    return page.evaluate(() => {
      const rect = (selector: string) => {
        const { top, bottom, left, right } = document.querySelector(selector)!.getBoundingClientRect();
        return { top, bottom, left, right };
      };
      return { menu: rect(".acpmux-cloud-env-menu"), chip: rect(".acpmux-cloud-env"), box: rect("[data-gallery-box]") };
    });
  };

  for (const [variant, place] of [
    ["drop-up-list", "a chat's composer at the bottom"],
    ["drop-up-gear", "a chat's composer at the bottom, gear rows"],
    ["drop-up-sections", "a chat's composer at the bottom, sections"],
    ["drop-up-picked", "a chat's composer at the bottom, an environment picked"],
    ["drop-up-new-tab", "the New Tab page's composer in the top half"],
  ] as const) {
    for (const width of [400, 620]) {
      test(`the drop-up opens above the chip and never over the composer: ${place}, ${width} px`, async () => {
        const page = await open(variant, width);
        try {
          const { menu, chip, box } = await openDropUp(page);
          expect(menu.bottom).toBeLessThanOrEqual(chip.top + 0.5);
          expect(menu.bottom).toBeLessThanOrEqual(box.top + 0.5);
        } finally {
          await page.close();
        }
      });
    }
  }

  test("picking Cloud opens the chip at the strip's end: Project and Where do not move, and nothing pops in", async () => {
    const page = await open("this-mac");
    try {
      const before = await page.evaluate(() =>
        [...document.querySelectorAll(".acpmux-location-leading > .acpmux-location-picker")].map(
          (picker) => picker.getBoundingClientRect().left,
        ),
      );
      const closed = await page.evaluate(
        () => document.querySelector(".acpmux-cloud-env-slot")!.getBoundingClientRect().width,
      );
      expect(closed).toBeLessThanOrEqual(0.5);
      await page.click('[data-rows="where"] button');
      await page.click('.acpmux-env-row[data-mode="cloud"]');
      await page.waitForSelector('.acpmux-cloud-env-slot[data-shown="true"]');
      // Settled: the column is open and the chip fully drawn, with no step after the transition.
      await page.waitForFunction(() => {
        const slot = document.querySelector(".acpmux-cloud-env-slot")!;
        const chip = slot.querySelector(".acpmux-cloud-env")!;
        return getComputedStyle(slot).opacity === "1" && slot.getBoundingClientRect().width >= chip.scrollWidth - 0.5;
      });
      const after = await page.evaluate(() =>
        [...document.querySelectorAll(".acpmux-location-leading > .acpmux-location-picker")].map(
          (picker) => picker.getBoundingClientRect().left,
        ),
      );
      // The Project and Where chips start where they started.
      expect(after.slice(0, before.length)).toEqual(before);
    } finally {
      await page.close();
    }
  });
});
