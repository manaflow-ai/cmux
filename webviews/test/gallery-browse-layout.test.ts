// The browse shell must remain usable at the narrow width used by the gallery matrix. This lane
// uses the real shell stylesheet and the same control/card structure as the React shell, then
// checks browser geometry rather than looking for a CSS declaration.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("gallery-browse-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  const shellCss = fs.readFileSync(
    path.resolve(import.meta.dir, "../src/gallery/shell/shell.css"),
    "utf8",
  );
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      // The matrix installs the engines it runs. Keep the lane useful on a host with only one.
    }
  }

  const pageMarkup = (css: string) => `<!doctype html>
    <html><head><style>${css}</style></head><body>
      <div class="gallery">
        <aside class="gallery-list"></aside>
        <main class="gallery-main">
          <header class="gallery-header">
            <h1>Transcript</h1>
            <div class="gallery-controls">
              <label>Locale <select><option>English</option></select></label>
              <label>Theme <select><option>Dark</option></select></label>
              <fieldset class="gallery-segmented">
                <legend>Appearance</legend>
                <label><input type="radio" checked>auto</label>
                <label><input type="radio">dark</label>
                <label><input type="radio">light</label>
              </fieldset>
            </div>
          </header>
          <section class="gallery-browse">
            <div class="gallery-browse-grid">
              <article class="gallery-browse-card">
                <header class="gallery-browse-card-header"><div><h2>Transcript</h2><code>agent-pane.transcript</code></div><span>Motion</span></header>
                <div class="gallery-browse-variants"><button>idle</button><button>streaming</button></div>
                <figure class="gallery-stage"><div class="gallery-window" style="width:420px;height:220px"><iframe title="preview" style="width:1664px;height:872px"></iframe></div></figure>
              </article>
            </div>
          </section>
        </main>
      </div>
    </body></html>`;

  async function measure(page: Page) {
    return page.evaluate(() => {
      const rect = (selector: string) => {
        const node = document.querySelector<HTMLElement>(selector);
        if (!node) throw new Error(`missing ${selector}`);
        const box = node.getBoundingClientRect();
        return { left: box.left, right: box.right, width: box.width };
      };
      return {
        viewport: innerWidth,
        documentWidth: document.documentElement.scrollWidth,
        main: rect(".gallery-main"),
        controls: rect(".gallery-controls"),
        segmented: rect(".gallery-segmented"),
        card: rect(".gallery-browse-card"),
        window: rect(".gallery-window"),
      };
    });
  }

  for (const [name, type] of engines) {
    describe(`gallery browse layout in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await type.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      test("the 390px browse shell wraps controls and keeps previews inside the viewport", async () => {
        const page = await browser.newPage({ viewport: { width: 390, height: 760 } });
        await page.setContent(pageMarkup(shellCss));
        const layout = await measure(page);
        expect(layout.documentWidth).toBeLessThanOrEqual(layout.viewport);
        expect(layout.segmented.right).toBeLessThanOrEqual(layout.viewport);
        expect(layout.segmented.right).toBeLessThanOrEqual(layout.controls.right);
        expect(layout.card.right).toBeLessThanOrEqual(layout.main.right);
        expect(layout.window.width).toBeLessThanOrEqual(layout.card.width);
        await page.close();
      });
    });
  }
});
