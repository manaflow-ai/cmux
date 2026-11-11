// l10n-allow-file: test fixtures.
// The selection's Reply chip (SelectionReply.tsx): it shows when a transcript selection ends,
// quotes the selection through Quote in Reply when clicked, and goes when the selection collapses.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SelectionReplyChip } from "./SelectionReply";
import { configureSelectionReply, quoteMarkdown, selectionReplyPlace, setQuoteReplySink } from "./selectionReplyModel";

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

test("the chip never covers the Sent to line over the selected reply, nor the reply's other words", () => {
  const doc = mount(SENT_OVER_REPLY);
  const restore = layOut(doc);
  try {
    // "only on 429": its end, x 160, is under the Sent to line's words (x 24 to 280).
    select(doc, "prose", 6, 17);
    const button = chip(doc)!;
    expect(button).not.toBeNull();
    const left = parseFloat(button.style.left);
    const top = parseFloat(button.style.top);
    const pill = { left, top, right: left + 72, bottom: top + 28 };
    const label = { left: 24, right: 24 + 32 * 8, ...LINES.sent };
    const hits = (a: typeof pill, b: typeof pill) =>
      a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
    const prose = { left: 24, right: 24 + 26 * 8, ...LINES.prose };
    expect(hits(pill, label)).toBe(false);
    expect(hits(pill, prose)).toBe(false);
    // Text over the end and after it on its line: just under the line, centred on "429"'s end.
    expect({ left, top }).toEqual({ left: 160 - 36, top: LINES.prose.bottom + 6 });
  } finally {
    restore();
  }
});

// The placement alone (selectionReplyPlace): a 72 x 28 chip, a selection whose last line is the
// 22 px line from y 200, in a column from x 100 to x 820 of a 1040 x 700 pane. The probe answers
// the unselected text boxes crossing a spot, out of a fixed list: lines 18 px high, the line over
// the selection's last at 178 and the one under it at 228.
type Rect = { left: number; right: number; top: number; bottom: number };
const SIZE = { width: 72, height: 28 };
const PANE = { width: 1040, height: 700 };
const COLUMN = { left: 100, right: 820 };
const row = (top: number, right = 820, left = 100): Rect => ({ left, right, top, bottom: top + 18 });
const OVER = row(178);
const UNDER = row(228);
/// The unselected rest of the selection's last line, from `from` to `to`.
const rest = (from: number, to = 820): Rect => ({ left: from, right: to, top: 200, bottom: 222 });
/// A selection from the line's start (or `start`) to `right`.
const at = (right: number, start = 100) => ({
  text: "x",
  left: right,
  top: 200,
  bottom: 222,
  end: { right, top: 200, bottom: 222 },
  lineStart: start,
  column: COLUMN,
});
const hit = (a: Rect, b: Rect) =>
  Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
  Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;
/// Every probe the placement makes is recorded, so a test can see it measured each spot it took.
const probeOf = (text: readonly Rect[]) => (box: Rect) => text.filter((rect) => hit(box, rect));
const chipBox = (place: { left: number; top: number }): Rect => ({
  left: place.left,
  top: place.top,
  right: place.left + 72,
  bottom: place.top + 28,
});
/// Whether a placed chip covers `rect`; a hidden chip (undefined) fails the test.
const covers = (place: { left: number; top: number } | undefined, rect: Rect) => {
  expect(place).toBeDefined();
  return hit(chipBox(place!), rect);
};

test("a clear spot over the selection's end keeps the chip there, centred on the end", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE, probeOf([rest(400)]))).toEqual({ left: 364, top: 166 });
});

test("a selection that ends its line, text over it: inline, just after the end and centred on the line", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE, probeOf([OVER, UNDER]))).toEqual({ left: 406, top: 197 });
});

test("a mid-line end with text over it and after it: just under the end when that is free", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE, probeOf([OVER, rest(400)]))).toEqual({ left: 364, top: 228 });
});

test("a mid-line end with a short line under it: the nearest free spot in that row", () => {
  const text = [OVER, rest(400), row(228, 420)];
  const place = selectionReplyPlace(at(400), SIZE, PANE, probeOf(text));
  expect(place).toEqual({ left: 426, top: 228 });
  for (const rect of text) expect(covers(place, rect)).toBe(false);
});

test("a right-edge end mid-paragraph, no free spot near: over the selection's own last words, never others'", () => {
  const text = [OVER, rest(810), UNDER];
  // The end is at x 810; "after" (816 to 888) would run past the column's 820.
  const ownEnd = selectionReplyPlace(at(810), SIZE, PANE, probeOf(text));
  expect(ownEnd).toEqual({ left: 738, top: 197 });
  const ownStart = selectionReplyPlace(at(810), SIZE, PANE, probeOf(text), "own-start");
  expect(ownStart).toEqual({ left: 100, top: 197 });
  for (const place of [ownEnd, ownStart]) for (const rect of text) expect(covers(place, rect)).toBe(false);
  // Farther: two lines up is clear, so it goes there, at the column's edge nearest the end.
  expect(selectionReplyPlace(at(810), SIZE, PANE, probeOf(text), "farther")).toEqual({ left: 748, top: 144 });
});

test("the chip never leaves the visible transcript: on its first or last line", () => {
  // The last line: inline would end at 225, past the visible foot (226 less its 2 px).
  const last = selectionReplyPlace(at(400), SIZE, { width: 1040, height: 226 }, probeOf([OVER]));
  expect(last!.top + 28).toBeLessThanOrEqual(224);
  expect(covers(last, OVER)).toBe(false);
  // The first line: the spot over it is above the visible top (194 plus its 2 px).
  const first = selectionReplyPlace(at(400), SIZE, { width: 1040, height: 700, top: 194 }, probeOf([rest(400), UNDER]));
  expect(first!.top).toBeGreaterThanOrEqual(196);
  expect(covers(first, UNDER)).toBe(false);
  expect(covers(first, rest(400))).toBe(false);
});

// Review on #37507 (a0209697): a short selection at y 200 to 222 in dense text put the chip at
// y 100, over two unselected lines that the placement had never measured.
test("two short words in dense text: each spot measured where it is, never a far line taken as empty", () => {
  // Text lines every 26 px from y 70 to 330 (an 8 px gap, less than the chip); the selection is
  // 400 to 450 on the 200 line.
  const text: Rect[] = [];
  for (let k = -5; k <= 5; k += 1) if (k !== 0) text.push(row(200 + 26 * k));
  text.push(rest(100, 400), rest(450));
  const place = selectionReplyPlace(at(450, 400), SIZE, PANE, probeOf(text));
  // Nothing near is free and the full chip would cover the prefix: its glyph alone (28 px) over
  // the selection's own words, covering nothing else.
  expect(place).toEqual({ left: 422, top: 197, compact: true });
  const glyph = { left: 422, right: 450, top: 197, bottom: 225 };
  for (const rect of text) expect(hit(glyph, rect)).toBe(false);
  // A selection narrower than the glyph (400 to 410): no spot covers only its own words, so the
  // chip hides rather than cover anyone else's.
  const narrow = [...text.filter((rect) => rect.top !== 200), rest(100, 400), rest(410)];
  expect(selectionReplyPlace(at(410, 400), SIZE, PANE, probeOf(narrow))).toBeUndefined();
});

// Review on #37507 (698288c9): a short prompt right-aligned in its bubble has a column narrower
// than the chip; the chip ran past the pane.
test("a column narrower than the chip: the chip is bounded by the pane instead, never past it", () => {
  const prompt = { ...at(368, 348), left: 368, column: { left: 348, right: 368 } };
  const place = selectionReplyPlace(prompt, SIZE, { width: 400, height: 700 }, probeOf([]))!;
  expect(place).toEqual({ left: 400 - 6 - 72, top: 166 });
});

// Review on #37507 (698288c9): a selection scrolled out of the visible transcript put the chip at
// its edge, over other text.
test("a selection whose last line is out of the visible transcript hides the chip", () => {
  expect(selectionReplyPlace(at(400), SIZE, { width: 1040, height: 700, top: 230 }, probeOf([]))).toBeUndefined();
  expect(selectionReplyPlace(at(400), SIZE, { width: 1040, height: 190 }, probeOf([]))).toBeUndefined();
});

test("a backward multi-line drag: spots near its end are measured there, not near where it started", () => {
  // Dragged from x 400 on the 200 line back to x 300 on the 156 line; the line between is selected.
  const target = { ...at(400), left: 300, top: 156, bottom: 178 };
  const text = [row(134), rest(400), UNDER, row(156, 300)];
  const place = selectionReplyPlace(target, SIZE, PANE, probeOf(text));
  for (const rect of text) expect(covers(place, rect)).toBe(false);
  // Over the selected line between, nearest the end.
  expect(place).toEqual({ left: 364, top: 166 });
});
