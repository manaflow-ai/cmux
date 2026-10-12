// Scrollbars are thin and show only while scrolling, app-wide (Leo 2026-10-12: "a page-level thick
// gray bar at the window edge", "never a permanent gray track"). With macOS "Show scroll bars" set
// to Always, WebKit draws a legacy bar on every scroller that overflows; the shared scroller rules
// (scrollers.ts, installed on every page) draw a thin themed one instead, with no track, hidden at
// rest and shown while the element scrolls. This renders those rules in Chromium, whose default
// bars are legacy ones, and reads the scroller's strip.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { SCROLLER_ROOT_CSS, SCROLLING_ATTRIBUTE } from "../src/scrollers";
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

  let page: Page;
  beforeAll(async () => {
    page = await browser!.newPage({ viewport: { width: 400, height: 300 } });
    await page.setContent(`<!doctype html>
      <html data-scrollers="legacy" style="color:#fff;background:#202020">
      <style>${SCROLLER_ROOT_CSS}</style>
      <body style="margin:0">
        <div id="list" style="width:200px;height:200px;overflow:auto;background:#202020">
          <div style="height:2000px"></div>
        </div>
      </body></html>`);
  });

  /** The scroller's width, and how many pixels of its strip differ from the page background. */
  async function strip() {
    const width = await page.evaluate(() => {
      const list = document.getElementById("list")!;
      return list.offsetWidth - list.clientWidth;
    });
    const shot = await page.screenshot({
      clip: { x: 200 - Math.max(width, 1), y: 0, width: Math.max(width, 1), height: 200 },
    });
    const pixels = await page.evaluate(async (base64) => {
      const image = new Image();
      image.src = `data:image/png;base64,${base64}`;
      await image.decode();
      const canvas = Object.assign(document.createElement("canvas"), { width: image.width, height: image.height });
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      const data = context.getImageData(0, 0, image.width, image.height).data;
      let differ = 0;
      for (let index = 0; index < data.length; index += 4)
        if (Math.abs(data[index]! - 0x20) + Math.abs(data[index + 1]! - 0x20) + Math.abs(data[index + 2]! - 0x20) > 24)
          differ += 1;
      return differ;
    }, shot.toString("base64"));
    return { width, drawn: pixels > 0 };
  }

  test("Always: a thin bar, nothing drawn at rest, the thumb shown while scrolling", async () => {
    const rest = await strip();
    await page.evaluate(
      (attribute) => document.getElementById("list")!.setAttribute(attribute, ""),
      SCROLLING_ATTRIBUTE,
    );
    const scrolling = await strip();
    expect({ thin: rest.width > 0 && rest.width <= 8, rest: rest.drawn, scrolling: scrolling.drawn }).toEqual({
      thin: true,
      rest: false,
      scrolling: true,
    });
  });
});
