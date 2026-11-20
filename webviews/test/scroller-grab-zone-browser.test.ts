// cmux-web-test-timeout: 420
// Lawrence 2026-11-20 (msg 42498): "for scrollbar, it is possible for me to hover close, and for the
// width to change, but after i mousedown and drag, it fails to scroll. fix so we get it pixel
// perfect". In a real engine (WebKit is the app's; Chromium too), column by column from a scroller's
// trailing edge in, on its thumb and on its track: the pointer marks the scroller near (its thumb
// widens) exactly where a press and a drag scroll it. The pure geometry is scroller-grab-zone.test.ts.
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

      for (const kind of ["legacy", "shown"] as const)
        for (const [row, y] of [
          ["thumb", 8],
          ["track", 150],
        ] as const)
          test(`${kind}, on the ${row}: near exactly where a press and a drag scroll`, async () => {
            const page = await open(kind);
            try {
              const mismatches: string[] = [];
              let near = 0;
              for (let column = 0; column < 32; column += 1) {
                await page.mouse.move(40, 100);
                await page.evaluate(() => {
                  document.getElementById("list")!.scrollTop = 0;
                });
                await frames(page);
                const x = 200 - column - 0.5;
                await page.mouse.move(x, y, { steps: 2 });
                await frames(page);
                const marked = await page.evaluate(
                  (name) => document.getElementById("list")!.hasAttribute(name),
                  NEAR_ATTRIBUTE,
                );
                await page.mouse.down();
                await page.mouse.move(x, y + 40, { steps: 4 });
                await page.mouse.up();
                const scrolled = await page.evaluate(() => document.getElementById("list")!.scrollTop > 0);
                if (marked) near += 1;
                if (marked !== scrolled)
                  mismatches.push(`column ${column}: near ${marked}, a drag scrolls ${scrolled}`);
              }
              expect({ mismatches, someNear: near > 0 }).toEqual({ mismatches: [], someNear: true });
            } finally {
              await page.close();
            }
          });
    });
  }
});
