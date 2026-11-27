// Scrollbars are thin and show only while scrolling, app-wide (Leo 2026-10-12: "a page-level thick
// gray bar at the window edge", "never a permanent gray track"). With macOS "Show scroll bars" set
// to Always, WebKit draws a legacy bar on every scroller that overflows; the shared scroller rules
// (scrollers.ts, installed on every page) draw a thin themed one instead, with no track, hidden at
// rest and shown while the element scrolls, however it scrolls (wheel, keys, find, code), the
// page's own scroller included. This installs the real module in a page with legacy bars and reads
// the scroller's strip.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thin-scrollers.test.ts", async () => {
  setDefaultTimeout(60_000);
  let browser: Browser | undefined;
  try {
    // Headless Chromium hides scrollbars unless told not to.
    browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
  } catch {
    console.warn("thin-scrollers: skipping (run `bunx playwright install chromium`)");
    describe.skip("thin scrollers", () => test("chromium", () => {}));
    return;
  }
  afterAll(async () => browser?.close());

  // The shipped module, bundled for the page: `installScrollers` as every page calls it.
  let bundle = "";
  beforeAll(async () => {
    const entry = path.join(mkdtempSync(path.join(tmpdir(), "thin-scrollers-")), "entry.ts");
    writeFileSync(
      entry,
      `import { installScrollers } from ${JSON.stringify(path.resolve(import.meta.dir, "../src/scrollers.ts"))};
       installScrollers(document);`,
    );
    const built = await Bun.build({ entrypoints: [entry], target: "browser", format: "iife" });
    bundle = await built.outputs[0]!.text();
  });

  async function open(root: boolean): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 400, height: 300 } });
    await page.setContent(`<!doctype html>
      <html data-scrollers="legacy" style="color:#fff;background:#202020">
      <body style="margin:0;background:#202020">
        ${
          root
            ? `<div style="height:3000px"></div>`
            : `<div id="list" style="width:200px;height:200px;overflow:auto"><div style="height:2000px"></div></div>`
        }
      </body></html>`);
    await page.addScriptTag({ content: bundle });
    await installPaintedFrames(page);
    return page;
  }

  /** The scroller's width, and whether anything is drawn in its strip (the page is #202020). */
  async function strip(page: Page, root: boolean) {
    const box = await page.evaluate((root) => {
      if (root) return { right: window.innerWidth, width: window.innerWidth - document.documentElement.clientWidth };
      const list = document.getElementById("list")!;
      return { right: list.getBoundingClientRect().right, width: list.offsetWidth - list.clientWidth };
    }, root);
    const width = Math.max(box.width, 1);
    const shot = await page.screenshot({ clip: { x: box.right - width, y: 0, width, height: 200 } });
    const drawn = await page.evaluate(async (base64) => {
      const image = new Image();
      image.src = `data:image/png;base64,${base64}`;
      await image.decode();
      const canvas = Object.assign(document.createElement("canvas"), { width: image.width, height: image.height });
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      const data = context.getImageData(0, 0, image.width, image.height).data;
      for (let index = 0; index < data.length; index += 4)
        if (Math.abs(data[index]! - 0x20) + Math.abs(data[index + 1]! - 0x20) + Math.abs(data[index + 2]! - 0x20) > 24)
          return true;
      return false;
    }, shot.toString("base64"));
    return { thin: box.width > 0 && box.width <= 8, drawn };
  }

  for (const root of [false, true]) {
    test(`Always, ${root ? "the page's own scroller" : "a scrolling box"}: thin, nothing at rest, shown while it scrolls without a wheel`, async () => {
      const page = await open(root);
      const rest = await strip(page, root);
      // A key, find or code scroll: no wheel event.
      await page.evaluate((root) => {
        const target = root ? document.scrollingElement! : document.getElementById("list")!;
        target.scrollTop = 300;
      }, root);
      // The scroll marks the scroller as scrolling, and a frame paints the bar.
      await page.waitForFunction(
        (root) =>
          (root ? document.documentElement : document.getElementById("list")!).hasAttribute("data-cmux-scrolling"),
        root,
        { timeout: 5_000 },
      );
      await page.evaluate(() => window.cmuxPaintFrame());
      const scrolling = await strip(page, root);
      await page.close();
      expect({ thin: rest.thin, rest: rest.drawn, scrolling: scrolling.drawn }).toEqual({
        thin: true,
        rest: false,
        scrolling: true,
      });
    });
  }
});
