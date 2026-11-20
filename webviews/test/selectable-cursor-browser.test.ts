// l10n-allow-file: test fixtures.
// What is inside selectable text shows the arrow or the I-beam (`cursor: auto`) whatever cursor a box
// between it and the `.selectable` sets, as desktop.css's `:where(.selectable, .selectable *)` gave it
// before the rule was made cheaper to match. The Markdown page's diagram and raw HTML previews
// (pages/markdown/styles.css `.md-diagram`, `.md-raw-preview`: `cursor: text`, contentEditable=false,
// inside `.md-doc.selectable`) give their own box the I-beam, but their SVG shapes, images and empty
// space keep `auto`, so the arrow shows there; a clickable thing in or around selectable text still
// gives everything in it its arrow. Real engines on the page's own sheets (desktop.css, then the
// Markdown page's), in page order, read with getComputedStyle.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

const src = join(import.meta.dir, "../src");
const SHEETS = ["pages/shared/desktop.css", "pages/markdown/styles.css"].map((path) =>
  readFileSync(join(src, path), "utf8").replace(/^@import .*$/gm, ""),
);

const PAGE = `
<div class="md-doc selectable">
  <div class="ProseMirror">
    <div class="md-code md-code-diagram">
      <div data-expect="text" data-name="diagram box" class="md-diagram" contenteditable="false">
        <svg data-expect="auto" data-name="diagram svg" width="40" height="40"><g data-expect="auto" data-name="diagram group"><rect data-expect="auto" data-name="diagram shape" width="10" height="10"></rect><text data-expect="auto" data-name="diagram label">A</text></g></svg>
        <div data-expect="auto" data-name="diagram's inner box"><span data-expect="auto" data-name="diagram's words">words</span></div>
      </div>
    </div>
    <div class="md-raw md-raw-html md-raw-has-preview">
      <div data-expect="text" data-name="raw preview box" class="md-raw-preview" contenteditable="false">
        <p data-expect="auto" data-name="raw preview paragraph">Raw <b data-expect="auto" data-name="raw preview bold">HTML</b></p>
        <img data-expect="auto" data-name="raw preview image" alt="" src="data:," />
        <a data-expect="default" data-name="raw preview link" href="https://example.com"><span data-expect="default" data-name="raw preview link words">link</span></a>
      </div>
    </div>
  </div>
</div>
<div class="selectable">
  <p data-expect="auto" data-name="selectable paragraph"><span data-expect="auto" data-name="selectable words">text</span></p>
  <a data-expect="default" data-name="chip" href="https://example.com"><span data-expect="default" data-name="chip label">chip</span></a>
  <div data-expect="default" data-name="role button" role="button"><span data-expect="default" data-name="role button words">go</span></div>
  <label data-expect="auto" data-name="field label"><span data-expect="auto" data-name="field label words">Name</span> <input data-expect="text" data-name="field" type="text" /></label>
</div>
<button data-expect="default" data-name="button"><div data-expect="default" data-name="selectable in a button" class="selectable"><span data-expect="default" data-name="its words">words</span></div></button>
<div data-expect="default" data-name="option" role="option"><div data-expect="default" data-name="selectable in an option" class="selectable"><p data-expect="default" data-name="its paragraph"><span data-expect="default" data-name="its deep words">deep</span></p></div></div>
`;

await requireBrowserLane("selectable-cursor-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("what is inside a box with its own cursor in selectable text keeps the cursor `.selectable *` gave it", async () => {
        const page = await browser!.newPage();
        await page.setContent(
          `<!doctype html><html><head>${SHEETS.map((css) => `<style>${css}</style>`).join("")}</head><body>${PAGE}</body></html>`,
        );
        const read = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement | SVGElement>("[data-expect]")].map((element) => ({
            name: element.dataset.name!,
            expect: element.dataset.expect!,
            cursor: getComputedStyle(element).cursor,
          })),
        );
        await page.close();
        expect(read.length).toBeGreaterThan(20);
        expect(Object.fromEntries(read.map(({ name, cursor }) => [name, cursor]))).toEqual(
          Object.fromEntries(read.map(({ name, expect }) => [name, expect])),
        );
      });
    });
  }
});
