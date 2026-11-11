// l10n-allow-file: test fixtures.
// The selection's Reply chip (SelectionReply.tsx): it shows when a transcript selection ends,
// quotes the selection through Quote in Reply when clicked, and goes when the selection collapses.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SelectionReplyChip } from "./SelectionReply";
import {
  configureSelectionReply,
  lastGlyph,
  quoteMarkdown,
  selectionReplyPlace,
  setQuoteReplySink,
} from "./selectionReplyModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
let unsink: (() => void) | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

function mount(body: string): Document {
  dom = new JSDOM(`<!doctype html><html><body>${body}<main id=root></main></body></html>`, {
    url: "http://localhost/",
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const doc = dom.window.document;
  root = createRoot(doc.getElementById("root")!);
  act(() => root!.render(<SelectionReplyChip doc={doc} />));
  return doc;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  unsink?.();
  unsink = undefined;
  configureSelectionReply("chip");
  for (const key of KEYS) {
    const value = saved.get(key);
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom?.window.close();
  dom = undefined;
});

const REPLY = `<div data-row-id="answer"><div class="cv-md"><p id=prose>Retry only on 429 and 503.</p>
<div class="cv-codeblock"><pre id=code>fetch(url)</pre></div></div></div>
<div class="acpmux-md-field" contenteditable="true"><p id=draft>draft</p></div>`;

function select(doc: Document, id: string, from = 0, to?: number) {
  const text = doc.getElementById(id)!.firstChild!;
  const range = doc.createRange();
  range.setStart(text, from);
  range.setEnd(text, to ?? text.textContent!.length);
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  act(() => {
    doc.dispatchEvent(new doc.defaultView!.Event("pointerup", { bubbles: true }));
  });
}

const chip = (doc: Document) => doc.querySelector<HTMLButtonElement>(".cv-selection-reply");

test("selecting transcript text shows the Reply chip at once", () => {
  const doc = mount(REPLY);
  expect(chip(doc)).toBeNull();
  select(doc, "prose", 6, 25);
  expect(chip(doc)).not.toBeNull();
  expect(chip(doc)!.textContent).toBe("Reply");
});

test("clicking the chip quotes the selection into the composer through Quote in Reply", () => {
  const doc = mount(REPLY);
  const quoted: string[] = [];
  unsink = setQuoteReplySink((markdown) => quoted.push(markdown));
  select(doc, "prose", 6, 25);
  act(() => chip(doc)!.click());
  expect(quoted).toEqual(["> only on 429 and 503\n\n"]);
  expect(quoted[0]).toBe(quoteMarkdown("only on 429 and 503"));
  expect(chip(doc)).toBeNull();
});

test("quoting keeps the caret the composer placed under the quote", () => {
  const doc = mount(REPLY);
  const field = doc.createElement("textarea");
  doc.body.append(field);
  unsink = setQuoteReplySink((markdown) => {
    field.value = markdown;
    field.focus();
    const caret = doc.createRange();
    caret.selectNodeContents(field);
    caret.collapse(false);
    doc.getSelection()!.removeAllRanges();
    doc.getSelection()!.addRange(caret);
  });
  select(doc, "prose", 6, 25);
  act(() => chip(doc)!.click());
  expect(doc.getSelection()!.rangeCount).toBe(1);
  expect(doc.getSelection()!.getRangeAt(0).startContainer).toBe(field);
  field.remove();
});

test("collapsing the selection removes the chip", () => {
  const doc = mount(REPLY);
  select(doc, "prose", 6, 25);
  expect(chip(doc)).not.toBeNull();
  act(() => {
    doc.getSelection()!.removeAllRanges();
    doc.dispatchEvent(new doc.defaultView!.Event("selectionchange"));
  });
  expect(chip(doc)).toBeNull();
});

test("no chip for text in a code block or the composer", () => {
  const doc = mount(REPLY);
  select(doc, "code");
  expect(chip(doc)).toBeNull();
  select(doc, "draft");
  expect(chip(doc)).toBeNull();
});

test("the right-click-only look draws no chip; the icon look draws the glyph alone", () => {
  const doc = mount(REPLY);
  act(() => configureSelectionReply("none"));
  select(doc, "prose", 6, 25);
  expect(chip(doc)).toBeNull();
  act(() => configureSelectionReply("icon"));
  select(doc, "prose", 6, 25);
  expect(chip(doc)!.textContent).toBe("");
  expect(chip(doc)!.getAttribute("aria-label")).toBe("Reply");
});

// A sent message's "Sent to <session>" line right over the reply, laid out as the pane draws them:
// one 22px line each, 8px a character from x 24. jsdom has no layout, so the rows, the text and the
// chip get these boxes (Leo, 2026-11-05, on the chip drawn over that line: "this is a bad reply").
const SENT_OVER_REPLY = `<div data-row-id="sent"><span id=sent>Sent to Debug Cloud release lane</span></div>
<div data-row-id="answer"><div class="cv-md"><p id=prose>Retry only on 429 and 503.</p></div></div>`;
const LINES: Record<string, { top: number; bottom: number }> = {
  sent: { top: 100, bottom: 122 },
  answer: { top: 128, bottom: 150 },
  prose: { top: 128, bottom: 150 },
};

function layOut(doc: Document): () => void {
  const view = doc.defaultView! as unknown as typeof globalThis & Window;
  const box = (left: number, right: number, line: { top: number; bottom: number }) =>
    new view.DOMRect(left, line.top, right - left, line.bottom - line.top);
  // Every text node here sits in an element with an id naming its line.
  const lineOf = (node: Node) => LINES[node.parentElement?.id ?? ""];
  const rangeRects = view.Range.prototype.getClientRects;
  const elementBox = view.Element.prototype.getBoundingClientRect;
  view.Range.prototype.getClientRects = function (this: Range) {
    const line = lineOf(this.startContainer);
    const rects = line ? [box(24 + this.startOffset * 8, 24 + this.endOffset * 8, line)] : [];
    return rects as unknown as DOMRectList;
  };
  view.Element.prototype.getBoundingClientRect = function (this: Element) {
    const line = LINES[this.getAttribute("data-row-id") ?? ""];
    return line ? box(0, 760, line) : box(0, 0, { top: 0, bottom: 0 });
  };
  const size = (name: "offsetWidth" | "offsetHeight", px: number) =>
    Object.defineProperty(view.HTMLElement.prototype, name, {
      configurable: true,
      get(this: HTMLElement) {
        return this.classList.contains("cv-selection-reply") ? px : 0;
      },
    });
  size("offsetWidth", 72);
  size("offsetHeight", 28);
  return () => {
    view.Range.prototype.getClientRects = rangeRects;
    view.Element.prototype.getBoundingClientRect = elementBox;
    delete (view.HTMLElement.prototype as unknown as Record<string, unknown>).offsetWidth;
    delete (view.HTMLElement.prototype as unknown as Record<string, unknown>).offsetHeight;
  };
}

test("the chip sits just after the selection's last character, on its line, never on the Sent to line over it", () => {
  const doc = mount(SENT_OVER_REPLY);
  const restore = layOut(doc);
  try {
    // "only on 429": its last character, "9", runs from x 152 to 160 on the 128 to 150 line.
    select(doc, "prose", 6, 17);
    const button = chip(doc)!;
    expect(button).not.toBeNull();
    const left = parseFloat(button.style.left);
    const top = parseFloat(button.style.top);
    const pill = { left, top, right: left + 72, bottom: top + 28 };
    const label = { left: 24, right: 24 + 32 * 8, ...LINES.sent };
    const hits = (a: typeof pill, b: typeof pill) =>
      a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
    expect(hits(pill, label)).toBe(false);
    // 6 px after "9", centred on its line.
    expect({ left, top }).toEqual({ left: 160 + 6, top: (128 + 150 - 28) / 2 });
  } finally {
    restore();
  }
});

test("a selection that runs into the next paragraph's start anchors to its last character, not the next line", () => {
  const doc = mount(SENT_OVER_REPLY);
  const restore = layOut(doc);
  try {
    // From "Retry" in the reply back to the Sent to line's start: a range that ends at offset 0 of
    // the next row's text, with its last character ("3") on the reply's line.
    const prose = doc.getElementById("prose")!.firstChild!;
    const sent = doc.getElementById("sent")!.firstChild!;
    const range = doc.createRange();
    range.setStart(sent, 25);
    range.setEnd(prose, 0);
    expect(lastGlyph(doc, range)!.rect.right).toBe(24 + 32 * 8);
    // The same, its end a point in the next row's element (a triple-click's range).
    range.setEnd(doc.querySelector('[data-row-id="answer"]')!, 0);
    expect(lastGlyph(doc, range)!.rect.right).toBe(24 + 32 * 8);
    range.setStart(prose, 6);
    range.setEnd(prose, 25);
    expect(lastGlyph(doc, range)!.rect.right).toBe(24 + 25 * 8);
    // Trailing spaces are not glyphs: the end goes back to the last character with ink.
    range.setEnd(prose, 11);
    expect(lastGlyph(doc, range)!.rect.right).toBe(24 + 10 * 8);
  } finally {
    restore();
  }
});

// The placement alone (selectionReplyPlace): a 72 x 28 chip, a selection whose last character ends
// at `right` on the 22 px line from y 200, in a column from x 100 to x 820 of a 1040 x 700 pane.
const SIZE = { width: 72, height: 28 };
const PANE = { width: 1040, height: 700 };
const COLUMN = { left: 100, right: 820 };
const at = (right: number, column: { left: number; right: number } | undefined = COLUMN) => ({
  text: "x",
  end: { left: right - 8, right, top: 200, bottom: 222 },
  column,
});
/// The chip centred on the 200 to 222 line.
const LINE = 197;

test("mid-line: just after the last character, centred on its line, whatever text is around", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE)).toEqual({ left: 406, top: LINE });
});

test("at the line's end, with room before the column's edge: just after the last character", () => {
  expect(selectionReplyPlace(at(740), SIZE, PANE)).toEqual({ left: 746, top: LINE });
});

test("at the column's right edge: flipped over the selection's own last words, on the same line", () => {
  // After the end (816 to 888) would run past the column's 820.
  expect(selectionReplyPlace(at(810), SIZE, PANE)).toEqual({ left: 810 - 72, top: LINE });
});

test("no room after the end nor over its own words: under the line, kept in the column", () => {
  // An 80 px column, a selection ending at its start: after (114 to 186) runs past 180, and its own
  // words (36 to 108) start left of the column.
  expect(selectionReplyPlace(at(108, { left: 100, right: 180 }), SIZE, PANE)).toEqual({ left: 100, top: 228 });
});

test("the chip never leaves the visible transcript: on its first or last line", () => {
  // The last line: centred, it would end at 225, past the visible foot (226 less its 2 px).
  const last = selectionReplyPlace(at(400), SIZE, { width: 1040, height: 226 })!;
  expect(last).toEqual({ left: 406, top: 226 - 2 - 28 });
  // The first line: centred, it would start at 197, over the visible top (198 plus its 2 px).
  expect(selectionReplyPlace(at(400), SIZE, { width: 1040, height: 700, top: 196 })).toEqual({ left: 406, top: 198 });
});

test("a short prompt in a bubble narrower than the chip: bounded by the pane, never past it", () => {
  // "OK" from 348 to 368 at the right of a 400 px pane: after (374 to 446) runs past 394, so the chip
  // flips over the prompt.
  expect(selectionReplyPlace(at(368, { left: 348, right: 368 }), SIZE, { width: 400, height: 700 })).toEqual({
    left: 368 - 72,
    top: LINE,
  });
});

test("a selection whose last line is out of the visible transcript hides the chip", () => {
  expect(selectionReplyPlace(at(400), SIZE, { width: 1040, height: 700, top: 230 })).toBeUndefined();
  expect(selectionReplyPlace(at(400), SIZE, { width: 1040, height: 190 })).toBeUndefined();
});

test("the over and under anchors take their spot first, then the same order", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE, "over")).toEqual({ left: 364, top: 200 - 6 - 28 });
  expect(selectionReplyPlace(at(400), SIZE, PANE, "under")).toEqual({ left: 364, top: 228 });
  // Over the first visible line there is no room: just after the end instead.
  expect(selectionReplyPlace(at(400), SIZE, { width: 1040, height: 700, top: 180 }, "over")).toEqual({
    left: 406,
    top: LINE,
  });
});
