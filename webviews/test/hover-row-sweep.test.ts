// Leo, 2026-10-14: a fast pointer sweep down a list or a menu lit each row it passed with a
// half-faded fill (rows fade their hover fill in over ~80 ms; at sweep speed the pointer is on each
// row for 2-3 frames, so every row flashed a partial tint). A row's hover fill now appears on the
// frame the pointer reaches it, with no fade-in (pages/shared/desktop.css, ui/hoverIntent.ts); it
// may still fade out, as the native sidebar's rows cross-fade (#20315).
//
// The page is the real stylesheets in a real engine: New Tab rows and agent-pane menu rows. The
// mouse sweeps them at 4 px a frame; every frame, any hovered row must already show its full fill.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hover-row-sweep.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const sheet = (...files: string[]) =>
    files
      .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
      .join("\n")
      .replace(/^@import .*$/gm, "");

  let browser: Browser;
  let page: Page;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 600, height: 600 } });
    await installPaintedFrames(page);
  });
  afterAll(async () => {
    await browser?.close();
  });

  /** Sweeps the pointer down `count` rows of `selector`; returns each frame's partial fills. */
  async function sweep(body: string, css: string, selector: string) {
    await page.setContent(
      `<!doctype html><html><head><style>${css}
      :root { --agent-motion-hover: 80ms; --agent-motion-hover-out: 0s; --acpmux-motion-hover: 80ms; }
      body { margin: 0; background: #fff; color: #000; }
      ${selector} { display: block; height: 28px; width: 300px; }
      </style></head><body>${body}</body></html>`,
    );
    await page.mouse.move(150, 2);
    await page.evaluate((rowSelector) => {
      const state = window as unknown as { partial: string[]; stop: boolean };
      state.partial = [];
      state.stop = false;
      const rows = [...document.querySelectorAll<HTMLElement>(rowSelector)];
      // The settled hover fill of each row: what a resting pointer shows.
      window.cmuxAfterPaint(() => {
        for (const row of rows) {
          if (!row.matches(":hover")) continue;
          const fill = getComputedStyle(row).backgroundColor;
          const target = row.dataset.fill;
          if (target && fill !== target) state.partial.push(`${row.id}: ${fill} (settles at ${target})`);
        }
        return !state.stop;
      });
    }, selector);
    // Each row's settled fill, measured with the pointer resting on it.
    const ids = await page.$$eval(selector, (rows) => rows.map((row) => row.id));
    for (const id of ids) {
      const box = (await page.locator(`#${id}`).boundingBox())!;
      await page.mouse.move(box.x + 150, box.y + 14);
      // Settled: the row is hovered and its fill transition has ended.
      await page.waitForFunction(
        (rowId) => {
          const row = document.getElementById(rowId)!;
          return row.matches(":hover") && row.getAnimations().length === 0;
        },
        id,
        { polling: "raf" },
      );
      await page.$eval(`#${id}`, (row) => {
        (row as HTMLElement).dataset.fill = getComputedStyle(row).backgroundColor;
      });
    }
    await page.mouse.move(150, 2);
    // Back at the top: only the first row is hovered, and no row is still fading.
    await page.waitForFunction(
      (rowSelector) =>
        [...document.querySelectorAll<HTMLElement>(rowSelector)].every(
          (row, index) => row.matches(":hover") === (index === 0) && row.getAnimations().length === 0,
        ),
      selector,
      { polling: "raf" },
    );
    await page.evaluate(() => {
      (window as unknown as { partial: string[] }).partial = [];
    });
    // The sweep: 4 px a painted frame, top to bottom, so each row is under the pointer for 7 frames
    // and every frame of the sweep is read.
    const end = ids.length * 28 + 10;
    for (let y = 2; y < end; y += 4) {
      await page.mouse.move(150, y);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    return page.evaluate(() => {
      const state = window as unknown as { partial: string[]; stop: boolean };
      state.stop = true;
      return state.partial;
    });
  }

  test("a fast sweep down the New Tab rows shows no half-faded fills", async () => {
    const rows = Array.from({ length: 6 }, (_, index) => `<a class="nt-row" id="r${index}">Chat ${index}</a>`).join("");
    const css = `${sheet("pages/shared/desktop.css", "agent-session/acpmux/newtab/screen.css")}
      .nt-row:hover { background: rgb(200, 200, 200); }`;
    expect(await sweep(rows, css, ".nt-row")).toEqual([]);
  });

  test("a fast sweep down the agent pane's menu rows shows no half-faded fills", async () => {
    const rows = Array.from(
      { length: 6 },
      (_, index) => `<div class="acpmux-question-row" id="q${index}">Option ${index}</div>`,
    ).join("");
    const css = `${sheet("pages/shared/desktop.css", "agent-session/acpmux/styles.css")}
      .acpmux-question-row:hover { background: rgb(200, 200, 200); }`;
    expect(await sweep(rows, css, ".acpmux-question-row")).toEqual([]);
  });
});
