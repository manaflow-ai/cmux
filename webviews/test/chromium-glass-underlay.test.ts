// Floating glass over a see-through Chromium page (glass.css, "CHROMIUM OVER THE WINDOW GLASS"; Leo
// 2026-10-22: "we can't be having unstyled main chat panes"). Chromium draws a backdrop-filter's
// blurred copy over the page's own pixels, so over a clear page (the window glass is not in it) the
// text under a menu or the composer reads crisp through the tint. The page here is clear too (the
// screenshot omits the background, as the app's see-through Chromium page does), with white bars
// for text under a floating glass and under a glass in the page's flow.
//
// Before: the bars under the floating glass kept most of their contrast (the "none" arm). After:
// the floating glass lays the theme surface under its tint, so they fade to a trace; the in-flow
// glass (a user's bubble) is unchanged by the arm; WebKit never draws the underlay.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chromium-glass-underlay.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");

  // Two glass boxes 200 x 80, each over white bars 2 px wide every 8 px.
  const FLOATING = { x: 20, y: 40 };
  const IN_FLOW = { x: 260, y: 40 };
  const BOX = { width: 200, height: 80 };
  // `page` is the page's own background: clear as over the window glass, or a grey as an opaque page.
  const html = (arm: string, page = "transparent") =>
    `<!doctype html><html data-cmux-see-through data-glass="plain" data-glass-underlay="${arm}"
       style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,30,30);background:${page}">
     <head><style>${css}
       body { margin: 0; background: transparent }
       .bars { position: absolute; top: 0; left: 0; width: 480px; height: 160px;
         background: repeating-linear-gradient(90deg, #fff 0 2px, transparent 2px 8px) }
       .box { position: absolute; width: ${BOX.width}px; height: ${BOX.height}px; border-radius: 12px;
         --glass-rim-shadow: 0 0 transparent }
     </style></head><body><div class="bars"></div>
     <div class="box ui-glass ui-glass-floats" id="floating" style="left:${FLOATING.x}px;top:${FLOATING.y}px"></div>
     <div class="box ui-glass" id="in-flow" style="left:${IN_FLOW.x}px;top:${IN_FLOW.y}px"></div>
     </body></html>`;

  async function open(browser: Browser, arm: string, background?: string): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 480, height: 160 }, deviceScaleFactor: 1 });
    await page.setContent(html(arm, background));
    return page;
  }

  /** How much the bars still show inside a box: the mean luminance gap between a bar column and the
   * gap beside it along the box's middle row, with the clear page laid over mid grey (the window). */
  async function barContrast(page: Page, box: { x: number; y: number }): Promise<number> {
    const png = PNG.sync.read(await page.screenshot({ omitBackground: true }));
    const y = box.y + BOX.height / 2;
    const at = (x: number) => {
      const i = (y * png.width + x) * 4;
      const alpha = png.data[i + 3]! / 255;
      // A PNG keeps straight alpha: lay each channel over grey 128 by its alpha.
      const channel = (c: number) => png.data[i + c]! * alpha + 128 * (1 - alpha);
      return 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2);
    };
    let sum = 0;
    let count = 0;
    // Bars sit at x % 8 in [0, 2); compare each bar's first column with the gap 4 px on.
    for (let x = box.x + 24; x + 4 < box.x + BOX.width - 24; x += 8) {
      sum += Math.abs(at(x - (x % 8)) - at(x - (x % 8) + 4));
      count++;
    }
    return sum / count;
  }

  describe("glass underlay in chromium", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await chromium.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    test("the bars under a floating glass fade to a trace; the in-flow glass is unchanged", async () => {
      const before = await open(browser, "none");
      const after = await open(browser, "medium");
      const crisp = await barContrast(before, FLOATING);
      const faded = await barContrast(after, FLOATING);
      // Without the underlay the clear page leaves the bars crisp under the tint.
      expect(crisp, "bars under the tint alone").toBeGreaterThan(30);
      expect(faded, "bars under the default underlay").toBeLessThan(crisp * 0.45);
      expect(await barContrast(after, IN_FLOW)).toBeCloseTo(await barContrast(before, IN_FLOW), 0);
      await before.close();
      await after.close();
    });

    // The cause, not the CSS: the same glass with no underlay frosts the bars away once the page
    // itself is opaque, because the blurred copy then covers what is under it.
    test("over an opaque page the tint alone already frosts the bars", async () => {
      const opaque = await open(browser, "none", "rgb(128, 128, 128)");
      expect(await barContrast(opaque, FLOATING)).toBeLessThan(8);
      await opaque.close();
    });

    test("the arms order by strength, and the glass is never opaque", async () => {
      const contrasts: number[] = [];
      for (const arm of ["none", "light", "medium", "heavy"]) {
        const page = await open(browser, arm);
        contrasts.push(await barContrast(page, FLOATING));
        const fill = await page.evaluate(() => getComputedStyle(document.getElementById("floating")!).backgroundColor);
        const alpha = Number(/[\d.]+(?=\s*\)$)/.exec(fill)?.[0] ?? 1);
        expect(alpha, `${arm} underlay alpha ${fill}`).toBeLessThan(0.9);
        await page.close();
      }
      for (let i = 1; i < contrasts.length; i++) expect(contrasts[i]!).toBeLessThan(contrasts[i - 1]!);
    });
  });

  describe("glass underlay in webkit", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await webkit.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    // WebKit's backdrop takes in the window glass and frosts the text itself: the tint alone.
    test("draws no underlay", async () => {
      const page = await open(browser, "medium");
      const image = await page.evaluate(() => getComputedStyle(document.getElementById("floating")!).backgroundImage);
      expect(image).toBe("none");
      await page.close();
    });
  });
});
