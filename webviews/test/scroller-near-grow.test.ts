// Lawrence 2026-10-23 (msg 11494): "the scrollbar stuff needs to be fixed so it auto-fades away, and
// grows bigger on near-hover so it's easier to grab". Every scroller the shared rules draw
// (scrollers.ts: macOS "Always", the chat's transcript and composer, cards) shows and widens its thumb
// while the pointer is near its trailing edge, and the chat's fading thumbs never flash for a scroll
// the user did not make (the transcript following new rows).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { SHOWN_SCROLLER_ATTRIBUTE } from "../src/scrollers";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("scroller-near-grow.test.ts", async () => {
  setDefaultTimeout(60_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
  } catch {
    console.warn("scroller-near-grow: skipping (run `bunx playwright install chromium`)");
    describe.skip("scroller near grow", () => test("chromium", () => {}));
    return;
  }
  afterAll(async () => browser?.close());

  let bundle = "";
  beforeAll(async () => {
    const entry = path.join(mkdtempSync(path.join(tmpdir(), "scroller-near-")), "entry.ts");
    writeFileSync(
      entry,
      `import { installScrollers } from ${JSON.stringify(path.resolve(import.meta.dir, "../src/scrollers.ts"))};
       installScrollers(document);`,
    );
    const built = await Bun.build({ entrypoints: [entry], target: "browser", format: "iife" });
    bundle = await built.outputs[0]!.text();
  });

  /** A 200 px scrolling box at the page's left: on "Always", or a chat transcript under the fade. */
  async function open(kind: "legacy" | "shown"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 400, height: 300 } });
    const root = kind === "legacy" ? `data-scrollers="legacy"` : `data-cmux-scroller-fade`;
    const list = kind === "shown" ? SHOWN_SCROLLER_ATTRIBUTE : "";
    await page.setContent(`<!doctype html>
      <html ${root} style="color:#fff;background:#202020">
      <body style="margin:0;background:#202020">
        <div id="list" ${list} style="width:200px;height:200px;overflow:auto"><div style="height:2000px"></div></div>
      </body></html>`);
    await page.addScriptTag({ content: bundle });
    await installPaintedFrames(page);
    return page;
  }

  /** How many columns of the box's scrollbar strip have thumb ink (the page is #202020). */
  async function inkColumns(page: Page): Promise<number> {
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => window.cmuxPaintFrame());
    const box = await page.evaluate(() => {
      const list = document.getElementById("list")!;
      return { right: list.getBoundingClientRect().right, width: list.offsetWidth - list.clientWidth };
    });
    const width = Math.max(box.width, 1);
    const shot = await page.screenshot({ clip: { x: box.right - width, y: 0, width, height: 120 } });
    return page.evaluate(async (base64) => {
      const image = new Image();
      image.src = `data:image/png;base64,${base64}`;
      await image.decode();
      const canvas = Object.assign(document.createElement("canvas"), { width: image.width, height: image.height });
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      const data = context.getImageData(0, 0, image.width, image.height).data;
      let columns = 0;
      for (let x = 0; x < image.width; x += 1) {
        for (let y = 0; y < image.height; y += 1) {
          const index = (y * image.width + x) * 4;
          if (
            Math.abs(data[index]! - 0x20) + Math.abs(data[index + 1]! - 0x20) + Math.abs(data[index + 2]! - 0x20) >
            24
          ) {
            columns += 1;
            break;
          }
        }
      }
      return columns;
    }, shot.toString("base64"));
  }

  for (const kind of ["legacy", "shown"] as const) {
    test(`${kind}: nothing at rest, a thumb near the edge, wider than while scrolling, gone when the pointer leaves`, async () => {
      const page = await open(kind);
      await page.mouse.move(40, 100);
      const rest = await inkColumns(page);
      await page.mouse.wheel(0, 200);
      await page.waitForFunction(() => document.getElementById("list")!.hasAttribute("data-cmux-scrolling"));
      const scrolling = await inkColumns(page);
      // The scrolling mark clears; the page has no fade durations, so the thumb goes at once.
      await page.waitForFunction(() => !document.getElementById("list")!.hasAttribute("data-cmux-scrolling"));
      const rested = await inkColumns(page);
      // Approach the edge from the content, as a hand does (the pointer stops short of the lane).
      await page.mouse.move(186, 100, { steps: 4 });
      await page.waitForFunction(() => document.getElementById("list")!.hasAttribute("data-cmux-scroller-near"));
      const near = await inkColumns(page);
      await page.mouse.move(40, 100);
      await page.waitForFunction(() => !document.getElementById("list")!.hasAttribute("data-cmux-scroller-near"));
      const left = await inkColumns(page);
      await page.close();
      expect({ rest, rested, left, scrolls: scrolling > 0, wider: near > scrolling }).toEqual({
        rest: 0,
        rested: 0,
        left: 0,
        scrolls: true,
        wider: true,
      });
    });
  }

  test("a chat transcript under the fade does not flash when the page scrolls it to new rows", async () => {
    const page = await open("shown");
    // No wheel, key or button yet: a pointer move is not one.
    await page.mouse.move(40, 100);
    await page.evaluate(() => {
      document.getElementById("list")!.scrollTop = 1800; // the view following a new row
    });
    await page.evaluate(() => window.cmuxPaintFrame());
    const marked = await page.evaluate(() => document.getElementById("list")!.hasAttribute("data-cmux-scrolling"));
    const ink = await inkColumns(page);
    await page.close();
    expect({ marked, ink }).toEqual({ marked: false, ink: 0 });
  });
});
