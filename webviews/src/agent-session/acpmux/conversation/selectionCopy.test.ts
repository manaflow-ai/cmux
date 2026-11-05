// l10n-allow-file: test fixtures.
// Cmd-C on a selection inside a reply (selectionCopy.ts): clean HTML with the reply's formatting and
// none of the transcript's classes, styles or buttons, and Markdown as its plain text.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { htmlMarkdown } from "../richClipboard";
import { selectionHtml } from "./selectionCopy";

const scope = globalThis as Record<string, unknown>;
const KEYS = ["document", "Node"];
const saved = new Map<string, unknown>();
let doc: Document;

beforeAll(() => {
  const dom = new JSDOM(`<!doctype html><html><body>
    <div class="cv-row"><div class="cv-md selectable" style="color: rgb(230, 230, 230)">
      <h2 class="cv-h" id="heading">Plan</h2>
      <ul class="cv-list"><li id="first"><strong style="font-weight:600">ship</strong> it</li><li id="last">then <a class="cv-link" href="https://example.com" data-chip="1">check</a><button>Copy</button></li></ul>
    </div></div>
    <div class="cv-md"><p id="other">another reply</p></div>
    <div class="cv-md"><p id="mathp">Area <span class="cv-math" data-tex="\\pi r^2"><span id="glyph">πr2</span></span> grows</p></div>
  </body></html>`);
  for (const key of KEYS) {
    saved.set(key, scope[key]);
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  doc = dom.window.document;
});
afterAll(() => {
  for (const key of KEYS) scope[key] = saved.get(key);
});

test("a selection in one reply copies as clean HTML and Markdown", () => {
  const range = doc.createRange();
  range.setStartBefore(doc.getElementById("heading")!);
  range.setEndAfter(doc.getElementById("last")!);
  const html = selectionHtml(range)!;
  expect(html).toContain("<h2>Plan</h2>");
  expect(html).toContain("<strong>ship</strong>");
  expect(html).toContain('<a href="https://example.com">check</a>');
  expect(html).not.toMatch(/class=|style=|data-|<button/);
  expect(htmlMarkdown(html)).toBe("## Plan\n\n- **ship** it\n- then [check](https://example.com)");
});

test("a selection across replies is the page's own copy", () => {
  const range = doc.createRange();
  range.setStartBefore(doc.getElementById("heading")!);
  range.setEndAfter(doc.getElementById("other")!);
  expect(selectionHtml(range)).toBeNull();
});

test("a selection that starts or ends inside an equation is mathCopy's", () => {
  const glyph = doc.getElementById("glyph")!.firstChild!;
  const range = doc.createRange();
  range.setStart(glyph, 1);
  range.setEnd(doc.getElementById("mathp")!.lastChild!, 3);
  expect(selectionHtml(range)).toBeNull();
  // All inside one equation: its clone holds only glyphs, no element with the TeX.
  const inside = doc.createRange();
  inside.setStart(glyph, 0);
  inside.setEnd(glyph, 2);
  expect(selectionHtml(inside)).toBeNull();
  const whole = doc.createRange();
  whole.selectNodeContents(doc.getElementById("mathp")!);
  expect(selectionHtml(whole)).toBeNull();
});
