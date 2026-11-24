// cmux-web-test-timeout: 420
// Lawrence 2026-11-20 (msg 42498): "for scrollbar, it is possible for me to hover close, and for the
// width to change, but after i mousedown and drag, it fails to scroll. fix so we get it pixel
// perfect". In a real engine (WebKit is the app's; Chromium too), column by column from a scroller's
// trailing edge in, on its thumb and on its track: the pointer marks the scroller near (its shown
// thumb widens) exactly where a press and a drag scroll it. The pure geometry is scroller-grab-zone.test.ts.
// Locally: CMUX_BROWSER_TESTS=1 and the file name, with the repo's test runner (never on a Mac).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { NEAR_ATTRIBUTE, SHOWN_SCROLLER_ATTRIBUTE } from "../src/scrollers";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("scroller-grab-zone-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let bundle = "";
  beforeAll(async () => {
    const entry = path.join(mkdtempSync(path.join(tmpdir(), "scroller-grab-")), "entry.ts");
    writeFileSync(
      entry,
      `import { installScrollers } from ${JSON.stringify(path.resolve(import.meta.dir, "../src/scrollers.ts"))};
       installScrollers(document);`,
    );
    const built = await Bun.build({ entrypoints: [entry], target: "browser", format: "iife" });
    bundle = await built.outputs[0]!.text();
  });

  for (const [engineName, engine] of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as const) {
    if (!(await probeEngineOrSkip("scroller-grab-zone-browser.test.ts", engineName, engine))) continue;
    describe(engineName, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
      });
      afterAll(async () => browser?.close());

      /** A 200 px box at the page's top left over 2000 px of content: "Always", or a chat transcript. */
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

      async function frames(page: Page): Promise<void> {
        await page.evaluate(() => window.cmuxPaintFrame());
        await page.evaluate(() => window.cmuxPaintFrame());
      }

      /** Puts the box at its top and waits until it stays there for 3 painted frames: a track press's
       *  page scroll animates on in Chromium, and a reset in its middle would let it scroll the box
       *  again, in the next column's press. */
      async function toTop(page: Page): Promise<void> {
        for (let attempt = 0; attempt < 120; attempt += 1) {
          const stays = await page.evaluate(async () => {
            const list = document.getElementById("list")!;
            list.scrollTop = 0;
            let top = 0;
            for (let frame = 0; frame < 3; frame += 1) {
              await window.cmuxPaintFrame();
              top = Math.max(top, list.scrollTop);
            }
            return top === 0;
          });
          if (stays) return;
        }
        throw new Error("the box never stayed at its top");
      }

      for (const kind of ["legacy", "shown"] as const)
        for (const [row, y] of [
          ["thumb", 8],
          // Clear of the bottom edge: a drag that ends near it autoscrolls a selection in the content.
          ["track", 110],
        ] as const)
          test(`${kind}, on the ${row}: near exactly where a press and a drag scroll`, async () => {
            const page = await open(kind);
            try {
              const mismatches: string[] = [];
              let near = 0;
              for (let column = 0; column < 32; column += 1) {
                await page.mouse.move(40, 100);
                await toTop(page);
                // Show the thumb as a person does, by scrolling (a wheel up at the top moves nothing):
                // the pointer near a hidden thumb marks nothing (Leo 2026-11-22).
                await page.mouse.wheel(0, -100);
                await page.waitForFunction(() => document.getElementById("list")!.hasAttribute("data-cmux-scrolling"));
                // The pixel column's left edge: engines hit-test whole pixels, so a half-pixel point rounds over.
                const x = 199 - column;
                await page.mouse.move(x, y, { steps: 2 });
                await frames(page);
                const marked = await page.evaluate(
                  (name) => document.getElementById("list")!.hasAttribute(name),
                  NEAR_ATTRIBUTE,
                );
                await page.mouse.down();
                await page.mouse.move(x, y + 30, { steps: 4 });
                await page.mouse.up();
                const scrolled = await page.evaluate(() => document.getElementById("list")!.scrollTop > 0);
                if (marked) near += 1;
                if (marked !== scrolled)
                  mismatches.push(`column ${column}: near ${marked}, a drag scrolls ${scrolled}`);
              }
              // An engine that draws an overlay scrollbar (no lane: headless WebKit on Linux) marks nothing
              // and takes no press on it; every engine that draws a lane must mark it.
              const lane = await page.evaluate(() => {
                const list = document.getElementById("list")!;
                return list.offsetWidth - list.clientWidth;
              });
              expect({ mismatches, marksTheLane: lane > 0 ? near === lane : near === 0 }).toEqual({
                mismatches: [],
                marksTheLane: true,
              });
            } finally {
              await page.close();
            }
          });
    });
  }
});
