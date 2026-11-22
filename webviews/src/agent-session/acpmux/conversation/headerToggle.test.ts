// l10n-allow-file: test fixture labels, not shipped UI.
// A header that is its toggle edge to edge (headerToggle.ts): a click on its padding, icon, words,
// counts or gaps toggles; a click on a control of its own (a button, a link, a chip with a role)
// does not, nor does a click whose target is outside it (a portal's content) or one that ends a
// text selection inside it.
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { togglesHeader } from "./headerToggle";

function header() {
  const { window } = new JSDOM(
    `<div id="head" data-header-toggle="">
       <span id="icon"><svg id="glyph"></svg></span>
       <div id="title"><span id="words">Edited MEMORY.md</span><span id="counts">+1 -0</span></div>
       <span id="chip" role="button" tabindex="0"><b id="chip-name">Grid fix</b></span>
       <button id="view">View changes</button>
       <button id="chevron" aria-expanded="false"><svg id="chevron-glyph"></svg></button>
       <a id="link" href="#x">link</a>
       <span id="sender" data-own-click=""><span id="sender-name">Grid fix</span></span>
     </div>
     <div id="outside">outside</div>`,
  );
  const document = window.document;
  const head = document.getElementById("head")!;
  return { window, document, head, at: (id: string) => togglesHeader(head, document.getElementById(id)) };
}

describe("togglesHeader", () => {
  for (const id of ["head", "icon", "glyph", "title", "words", "counts"])
    test(`a click on #${id} toggles`, () => {
      expect(header().at(id)).toBe(true);
    });
  // The chevron toggles through its own click handler, so the header must not toggle it again.
  for (const id of ["chip", "chip-name", "view", "chevron", "chevron-glyph", "link", "sender", "sender-name"])
    test(`a click on #${id} is that control's own`, () => {
      expect(header().at(id)).toBe(false);
    });
  test("a click whose target is outside the header (a portal) does nothing", () => {
    expect(header().at("outside")).toBe(false);
  });
  test("a click that ends a text selection in the header selects instead", () => {
    const { window, document, at } = header();
    const words = document.getElementById("words")!.firstChild!;
    window.getSelection()!.setBaseAndExtent(words, 0, words, 6);
    expect(at("words")).toBe(false);
    window.getSelection()!.removeAllRanges();
    expect(at("words")).toBe(true);
  });
});
