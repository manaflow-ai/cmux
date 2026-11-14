// l10n-allow-file: test fixtures.
// Cmd-C on a selection inside a reply (selectionCopy.ts): clean HTML with the reply's formatting and
// none of the transcript's classes, styles or buttons, and Markdown as its plain text.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
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
      <ul class="cv-list"><li id="first"><strong style="font-weight:600">ship</strong> it</li><li id="last">then <a class="cv-link" href="https://example.com" data-chip="1">check</a> <a href="javascript:alert(1)">run</a> <button class="cv-chip"><svg></svg>needs you</button><button aria-label="Copy"><svg></svg></button></li></ul>
      <p id="pic"><button class="cv-openable"><img class="cv-img" src="https://example.com/a.png" alt="chart"></button></p>
    </div></div>
    <div class="cv-md"><p id="other">another reply</p></div>
    <div class="cv-md"><ol class="cv-list cv-ol" start="3"><li id="o3"><span class="cv-li__num">3.</span><span class="cv-li__text">three</span></li><li id="o4"><span class="cv-li__num">4.</span><span id="t4" class="cv-li__text">four</span></li><li id="o5"><span class="cv-li__num">5.</span><span id="t5" class="cv-li__text">five</span></li></ol>
      <table><tbody><tr><td id="c1">alpha</td><td id="c2">beta</td></tr></tbody></table></div>
    <div class="cv-md"><p id="before-code">Run:</p><pre id="code"><div id="l1">if ready:</div><div id="l2">    run()</div></pre></div>
    <div class="cv-md"><p id="mathp">Area <span class="cv-math" data-tex="\\pi r^2"><span id="glyph">πr2</span></span> grows</p></div>
  </body></html>`);
  for (const key of KEYS) {
    saved.set(key, scope[key]);
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  doc = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of KEYS) {
    const value = saved.get(key);
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

test("a selection in one reply copies as clean HTML and Markdown", () => {
  const range = doc.createRange();
  range.setStartBefore(doc.getElementById("heading")!);
  range.setEndAfter(doc.getElementById("pic")!);
  const html = selectionHtml(range)!;
  // A visible button's words and picture stay; only its icon goes.
  expect(html).toContain("needs you");
  expect(html).toContain('<img src="https://example.com/a.png" alt="chart">');
  expect(html).toContain("<h2>Plan</h2>");
  expect(html).toContain("<strong>ship</strong>");
  expect(html).toContain('<a href="https://example.com/">check</a>');
  expect(html).not.toMatch(/class=|style=|data-|<button|javascript:/);
  expect(htmlMarkdown(html)).toBe("## Plan\n\n- **ship** it\n- then [check](https://example.com/) run needs you");
});

test("a selection across replies containing an image keeps browser copy", () => {
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

test("a selection inside a list keeps its list, an ordered one its numbers", () => {
  const range = doc.createRange();
  range.setStart(doc.getElementById("t4")!.firstChild!, 1);
  range.setEnd(doc.getElementById("t5")!.firstChild!, 2);
  const html = selectionHtml(range)!;
  expect(html).toMatch(/^<ol start="4"><li>/);
  // The drawn numbers ("4.") are not copied beside the list's own.
  expect(htmlMarkdown(html)).toBe("4. our\n5. fi");
});

test("a selection in or across code is the page's own copy, its lines and indentation kept", () => {
  const inside = doc.createRange();
  inside.setStart(doc.getElementById("l1")!.firstChild!, 0);
  inside.setEnd(doc.getElementById("l2")!.firstChild!, 9);
  expect(selectionHtml(inside)).toBeNull();
  const across = doc.createRange();
  across.setStartBefore(doc.getElementById("before-code")!);
  across.setEndAfter(doc.getElementById("code")!);
  expect(selectionHtml(across)).toBeNull();
});

test("a selection inside one table is the page's own copy, its cell separators kept", () => {
  const range = doc.createRange();
  range.setStart(doc.getElementById("c1")!.firstChild!, 0);
  range.setEnd(doc.getElementById("c2")!.firstChild!, 4);
  expect(selectionHtml(range)).toBeNull();
});
