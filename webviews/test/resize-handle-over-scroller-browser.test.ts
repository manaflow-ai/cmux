// cmux-web-test-timeout: 420
// Leo 2026-11-22: "when you're near the thumb and the sliding repositioner, it gets confused and
// sometimes goes to the thumb instead of the dragger." A resize handle (scrollers.ts
// RESIZE_HANDLE_ATTRIBUTE: SplitEdge's edge, Session Info's edge, the model menu's grips, ...) whose
// band overlaps a scroller's bar lane takes every press across the band: the installed rules stack it
// above the lane (RESIZE_HANDLE_CSS), even with the scroller positioned after it in the page, which
// would otherwise paint and hit-test over it. Pixel column by column across the band, in a real engine
// (WebKit is the app's; Chromium too), with the thumb shown from a scroll: the point hits the handle,
// a press there is the handle's pointerdown, a drag scrolls nothing, and the scroller is never marked
// near. The pure path check is scroller-hover-no-reveal.test.ts.
// Locally: CMUX_BROWSER_TESTS=1 and the file name, with the repo's test runner (never on a Mac).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { NEAR_ATTRIBUTE, RESIZE_HANDLE_ATTRIBUTE, SHOWN_SCROLLER_ATTRIBUTE } from "../src/scrollers";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("resize-handle-over-scroller-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let bundle = "";
  beforeAll(async () => {
    const entry = path.join(mkdtempSync(path.join(tmpdir(), "resize-handle-")), "entry.ts");
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
    if (!(await probeEngineOrSkip("resize-handle-over-scroller-browser.test.ts", engineName, engine))) continue;
    describe(engineName, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
      });
      afterAll(async () => browser?.close());

      /** A 200 px transcript under the fade ("Always" lanes) at the page's top left, and an 8 px handle
          band centred on its right edge (x 196 to 204), before it in the page and with no layer of its
          own: only the shared rule puts it over the positioned scroller. */
      async function open(): Promise<Page> {
        const page = await browser!.newPage({ viewport: { width: 400, height: 300 } });
        await page.setContent(`<!doctype html>
          <html data-scrollers="legacy" data-cmux-scroller-fade style="color:#fff;background:#202020">
          <body style="margin:0;background:#202020">
            <div style="position:relative;width:200px;height:200px">
              <div id="handle" ${RESIZE_HANDLE_ATTRIBUTE} style="position:absolute;top:0;bottom:0;left:196px;width:8px;cursor:col-resize"></div>
              <div id="list" ${SHOWN_SCROLLER_ATTRIBUTE} style="position:relative;width:200px;height:200px;overflow:auto"><div style="height:2000px"></div></div>
            </div>
          </body></html>`);
        await page.addScriptTag({ content: bundle });
        await installPaintedFrames(page);
        await page.evaluate(() => {
          const presses: string[] = [];
          (window as unknown as { presses: string[] }).presses = presses;
          document.addEventListener("pointerdown", (event) => presses.push((event.target as Element).id || "other"), {
            capture: true,
          });
        });
        return page;
      }

      test("a press at every x across the handle band is the handle's, and never marks or drags the thumb", async () => {
        const page = await open();
        try {
          const rows: string[] = [];
          for (let x = 196; x < 204; x += 1) {
            for (const y of [8, 100]) {
              await page.mouse.move(40, 100);
              await page.evaluate(() => {
                document.getElementById("list")!.scrollTop = 0;
              });
              // The thumb shows from a scroll (a wheel up at the top moves nothing).
              await page.mouse.wheel(0, -100);
              await page.waitForFunction(() => document.getElementById("list")!.hasAttribute("data-cmux-scrolling"));
              await page.mouse.move(x, y, { steps: 2 });
              await page.evaluate(() => window.cmuxPaintFrame());
              await page.evaluate(() => window.cmuxPaintFrame());
              const hit = await page.evaluate(
                ([x, y]) => document.elementFromPoint(x! + 0.5, y! + 0.5)?.id ?? "none",
                [x, y],
              );
              const near = await page.evaluate(
                (name) => document.getElementById("list")!.hasAttribute(name),
                NEAR_ATTRIBUTE,
              );
              await page.mouse.down();
              await page.mouse.move(x, y + 30, { steps: 4 });
              await page.mouse.up();
              const { press, scrolled } = await page.evaluate(() => ({
                press: (window as unknown as { presses: string[] }).presses.pop() ?? "none",
                scrolled: document.getElementById("list")!.scrollTop > 0,
              }));
              if (hit !== "handle" || press !== "handle" || near || scrolled)
                rows.push(`x ${x} y ${y}: hit ${hit}, press ${press}, near ${near}, scrolled ${scrolled}`);
            }
          }
          expect(rows).toEqual([]);
        } finally {
          await page.close();
        }
      });
    });
  }
});
