// l10n-allow-file: test fixtures.
// The selection's Reply chip (SelectionReply.tsx): it shows when a transcript selection ends,
// quotes the selection through Quote in Reply when clicked, and goes when the selection collapses.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SelectionReplyChip } from "./SelectionReply";
import {
  configureSelectionReply,
  quoteMarkdown,
  selectionReplyPlace,
  setQuoteReplySink,
  selectionReplyTarget,
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

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  unsink?.();
  unsink = undefined;
  configureSelectionReply("chip");
  await settleReact();
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

// conversation.css hides the chip while a cover is over the pane: a modal dialog (ui/Dialog.tsx, its
// `.ui-backdrop`) or the full-pane Computer Use preview. On the body at the dropdown layer, the chip
// drew over the image viewer's screenshot.
const COVER_RULE = (() => {
  const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
  const start = css.indexOf(":root:has(.ui-backdrop, .acpmux-cu-preview[data-full]) .cv-selection-reply {");
  if (start < 0) throw new Error("conversation.css has no cover rule for .cv-selection-reply");
  return css.slice(start, css.indexOf("}", start) + 1);
})();

for (const [name, html] of [
  ["a modal dialog", `<div class="ui-backdrop"></div>`],
  ["the full-pane Computer Use preview", `<div class="acpmux-cu-preview" data-full></div>`],
] as const) {
  test(`${name} over the pane hides the chip; it comes back when it closes`, () => {
    const doc = mount(REPLY);
    const style = doc.createElement("style");
    style.textContent = COVER_RULE;
    doc.head.append(style);
    select(doc, "prose", 6, 25);
    const view = doc.defaultView!;
    expect(view.getComputedStyle(chip(doc)!).visibility).not.toBe("hidden");
    const cover = doc.createElement("div");
    cover.innerHTML = html;
    doc.body.append(cover);
    expect(view.getComputedStyle(chip(doc)!).visibility).toBe("hidden");
    expect(view.getComputedStyle(chip(doc)!).pointerEvents).toBe("none");
    // A click inside the cover ends no new selection: the chip stays hidden.
    act(() => {
      doc.dispatchEvent(new view.Event("pointerup", { bubbles: true }));
    });
    expect(view.getComputedStyle(chip(doc)!).visibility).toBe("hidden");
    cover.remove();
    expect(view.getComputedStyle(chip(doc)!).visibility).not.toBe("hidden");
  });
}

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
// the text boxes crossing a spot, selected or not, out of a fixed list: lines 18 px high, the line
// over the selection's last at 178 and the one under it at 228, and the selection's own words.
type Rect = { left: number; right: number; top: number; bottom: number };
const SIZE = { width: 72, height: 28 };
const PANE = { width: 1040, height: 700 };
const COLUMN = { left: 100, right: 820 };
const row = (top: number, right = 820, left = 100): Rect => ({ left, right, top, bottom: top + 18 });
const OVER = row(178);
const UNDER = row(228);
/// The unselected rest of the selection's last line, from `from` to `to`.
const rest = (from: number, to = 820): Rect => ({ left: from, right: to, top: 200, bottom: 222 });
/// The selection's own words on its last line, from `start` to `right`.
const own = (right: number, start = 100): Rect => ({ left: start, right, top: 200, bottom: 222 });
/// A selection on the 200 line from the line's start (or `start`) to `right`.
const at = (right: number) => ({
  text: "x",
  left: right,
  top: 200,
  bottom: 222,
  end: { right, top: 200, bottom: 222 },
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
  expect(selectionReplyPlace(at(400), SIZE, PANE, probeOf([rest(400), own(400)]))).toEqual({ left: 364, top: 166 });
});

test("a selection that ends its line, text over it: inline, just after the end and centred on the line", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE, probeOf([OVER, UNDER, own(400)]))).toEqual({ left: 406, top: 197 });
});

test("a mid-line end with text over it and after it: just under the end when that is free", () => {
  expect(selectionReplyPlace(at(400), SIZE, PANE, probeOf([OVER, rest(400), own(400)]))).toEqual({
    left: 364,
    top: 228,
  });
});

test("a mid-line end with text right over and under it: a line further up, still over the end", () => {
  const text = [OVER, rest(400), row(228, 420), own(400)];
  const place = selectionReplyPlace(at(400), SIZE, PANE, probeOf(text));
  expect(place).toEqual({ left: 364, top: 144 });
  for (const rect of text) expect(covers(place, rect)).toBe(false);
});

test("a right-edge end mid-paragraph, text all round: a line further up, at the column's edge, over no words", () => {
  const text = [OVER, rest(810), UNDER, own(810)];
  // The end is at x 810; "after" (816 to 888) would run past the column's 820.
  const place = selectionReplyPlace(at(810), SIZE, PANE, probeOf(text));
  expect(place).toEqual({ left: 748, top: 144 });
  for (const rect of text) expect(covers(place, rect)).toBe(false);
});

test("the chip never leaves the visible transcript: on its first or last line", () => {
  // The last line: inline would end at 225, past the visible foot (226 less its 2 px).
  const last = selectionReplyPlace(at(400), SIZE, { width: 1040, height: 226 }, probeOf([OVER, own(400)]));
  expect(last!.top + 28).toBeLessThanOrEqual(224);
  expect(covers(last, OVER)).toBe(false);
  // The first line: the spot over it is above the visible top (194 plus its 2 px).
  const first = selectionReplyPlace(
    at(400),
    SIZE,
    { width: 1040, height: 700, top: 194 },
    probeOf([rest(400), UNDER, own(400)]),
  );
  expect(first!.top).toBeGreaterThanOrEqual(196);
  for (const rect of [UNDER, rest(400), own(400)]) expect(covers(first, rect)).toBe(false);
});

// Review on #37507 (a0209697): a short selection at y 200 to 222 in dense text put the chip at
// y 100, over two unselected lines that the placement had never measured.
test("two short words in dense text: each spot measured where it is, the nearest clear one above or below", () => {
  // Text lines every 26 px from y 70 to 330 (an 8 px gap, less than the chip); the selection is
  // 400 to 450 on the 200 line.
  const text: Rect[] = [];
  for (let k = -5; k <= 5; k += 1) if (k !== 0) text.push(row(200 + 26 * k));
  text.push(rest(100, 400), rest(450), own(450, 400));
  const place = selectionReplyPlace(at(450), SIZE, PANE, probeOf(text));
  // No spot between the lines holds the chip: it goes over the paragraph, centred on the end.
  expect(place).toEqual({ left: 414, top: 34 });
  for (const rect of text) expect(covers(place, rect)).toBe(false);
  // With text from the pane's top to its foot there is nowhere: the chip hides rather than cover any.
  const full: Rect[] = [];
  for (let y = 0; y < 700; y += 26) full.push(row(y));
  expect(selectionReplyPlace(at(450), SIZE, PANE, probeOf(full))).toBeUndefined();
});

// Review on #37507 (698288c9): a short prompt right-aligned in its bubble has a column narrower
// than the chip; the chip ran past the pane.
test("a column narrower than the chip: the chip is bounded by the pane instead, never past it", () => {
  const prompt = { ...at(368), left: 368, column: { left: 348, right: 368 } };
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
  const target = { ...at(400), left: 300, top: 156, bottom: 178, start: { top: 156, bottom: 178 } };
  const text = [row(134), rest(400), UNDER, row(156, 300), row(156, 820, 300), row(178), own(400)];
  const place = selectionReplyPlace(target, SIZE, PANE, probeOf(text));
  for (const rect of text) expect(covers(place, rect)).toBe(false);
  // Never over the selected line between: over the line before the selection, centred on the end.
  expect(place).toEqual({ left: 364, top: 100 });
});

// Leo, 2026-11-11 (ask-ee3b78191e): "this reply is in the wrong spot ... if you go close, you
// still get it. But if you go deep into it, there's something that messes up there." A drag that
// lets go deep in the blank space past a paragraph selects to the next block's start: the range's
// last box is caret-thin at that block's left. The chip goes over the last selected character.
const TWO_PARAGRAPHS = `<div data-row-id="answer"><div class="cv-md"><p id=first>Retry only on 429 and 503.</p>
<p id=second>Then give up.</p></div></div>`;

function selectAcross(doc: Document, boxes: Rect[], backward = false) {
  const view = doc.defaultView! as unknown as { Range: typeof Range };
  const range = doc.createRange();
  const first = doc.getElementById("first")!.firstChild!;
  const second = doc.getElementById("second")!.firstChild!;
  range.setStart(first, backward ? first.textContent!.length : 6);
  range.setEnd(second, backward ? 4 : 0);
  view.Range.prototype.getClientRects = () =>
    boxes.map((box) => ({
      ...box,
      width: box.right - box.left,
      height: box.bottom - box.top,
    })) as unknown as DOMRectList;
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  if (backward) {
    selection.setBaseAndExtent(second, 4, first, first.textContent!.length);
  } else selection.addRange(range);
}

test("a drag that ends deep in the blank space past a paragraph: the chip centres on its last character", () => {
  const doc = mount(TWO_PARAGRAPHS);
  // "only on 429 and 503." from x 148 to 308 on the 200 line, then a caret-thin box at the next
  // paragraph's start (x 100, the 240 line).
  selectAcross(doc, [
    { left: 148, right: 308, top: 200, bottom: 222 },
    { left: 100, right: 100, top: 240, bottom: 262 },
  ]);
  const target = selectionReplyTarget(doc)!;
  expect({ left: target.left, top: target.top, bottom: target.bottom }).toEqual({ left: 308, top: 200, bottom: 222 });
});

test("a backward drag that lets go deep in the blank space before a paragraph: the chip goes on its first character", () => {
  const doc = mount(TWO_PARAGRAPHS);
  // From "Then" on the 240 line back up past the end of the 200 line: a caret-thin box at the
  // first paragraph's end, then "Then".
  selectAcross(
    doc,
    [
      { left: 308, right: 308, top: 200, bottom: 222 },
      { left: 100, right: 132, top: 240, bottom: 262 },
    ],
    true,
  );
  const target = selectionReplyTarget(doc)!;
  expect({ left: target.left, top: target.top }).toEqual({ left: 100, top: 240 });
});

// Review of #41519: a drag let go deep below an agent's reply ends the range in the next row, a
// person's right-aligned bubble. The chip's column is the reply's, where the selected text is.
const REPLY_THEN_PROMPT = `<div data-row-id="answer"><div class="cv-md" id=answer-md><p id=first>Retry only on 429 and 503.</p></div></div>
<div data-row-id="prompt"><div class="cv-md" id=prompt-md><p id=second>Thanks.</p></div></div>`;

test("a drag let go deep in the next message: the chip keeps the selected text's column", () => {
  const doc = mount(REPLY_THEN_PROMPT);
  const view = doc.defaultView! as unknown as { Element: typeof Element };
  const boxes: Record<string, Rect> = {
    first: { left: 100, right: 820, top: 200, bottom: 222 },
    "answer-md": { left: 100, right: 820, top: 200, bottom: 222 },
    second: { left: 700, right: 820, top: 260, bottom: 282 },
    "prompt-md": { left: 700, right: 820, top: 260, bottom: 282 },
  };
  view.Element.prototype.getBoundingClientRect = function (this: Element) {
    const box = boxes[this.id] ?? { left: 0, right: 0, top: 0, bottom: 0 };
    return { ...box, width: box.right - box.left, height: box.bottom - box.top } as DOMRect;
  };
  selectAcross(doc, [
    { left: 148, right: 308, top: 200, bottom: 222 },
    { left: 700, right: 700, top: 260, bottom: 282 },
  ]);
  expect(selectionReplyTarget(doc)!.column).toEqual({ left: 100, right: 820 });
});

// User 2026-11-15 (CleanShot 8.08.35 PM): the Reply chip sat over the middle of a selection in the
// person's prompt, hiding the words they had just selected. The chip covers no text at all, the
// selection's own included: it goes above the selection or below it. A paragraph of four 22 px
// lines, 8 px a character from x 24; the first line is one short word, so the spot just over the
// selection's end lies over its own first line only.
const PARAGRAPH_LINES: Record<string, { top: number; bottom: number }> = {
  p0: { top: 100, bottom: 122 },
  p1: { top: 122, bottom: 144 },
  p2: { top: 144, bottom: 166 },
  p3: { top: 166, bottom: 188 },
};
const PARAGRAPH = `<div data-row-id="prompt"><p id=para><span id=p0>Hi</span><span id=p1>maybe it is a state ownership issue</span><span id=p2>please help me fix from first principles</span><span id=p3>This codebase is yours to keep building</span></p></div>`;

function layOutParagraph(doc: Document): () => void {
  const view = doc.defaultView! as unknown as typeof globalThis & Window;
  const box = (left: number, right: number, line: { top: number; bottom: number }) =>
    new view.DOMRect(left, line.top, right - left, line.bottom - line.top);
  const rangeRects = view.Range.prototype.getClientRects;
  const elementBox = view.Element.prototype.getBoundingClientRect;
  const texts = Object.keys(PARAGRAPH_LINES).map((id) => doc.getElementById(id)!.firstChild as Text);
  view.Range.prototype.getClientRects = function (this: Range) {
    const rects: DOMRect[] = [];
    for (const text of texts) {
      if (!this.intersectsNode(text)) continue;
      const from = text === this.startContainer ? this.startOffset : 0;
      const to = text === this.endContainer ? this.endOffset : text.length;
      if (to > from) rects.push(box(24 + from * 8, 24 + to * 8, PARAGRAPH_LINES[text.parentElement!.id]!));
    }
    return rects as unknown as DOMRectList;
  };
  view.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (this.id === "para" || this.getAttribute("data-row-id") === "prompt")
      return box(0, 760, { top: PARAGRAPH_LINES.p0!.top, bottom: PARAGRAPH_LINES.p3!.bottom });
    const line = PARAGRAPH_LINES[this.id];
    return line ? box(24, 24 + (this.textContent?.length ?? 0) * 8, line) : box(0, 0, { top: 0, bottom: 0 });
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

test("the chip never covers the selected text: it goes above or below the selection", () => {
  const doc = mount(PARAGRAPH);
  const restore = layOutParagraph(doc);
  try {
    // "it is a state ownership issue" on the second line through "please" on the third.
    const range = doc.createRange();
    range.setStart(doc.getElementById("p1")!.firstChild!, 6);
    range.setEnd(doc.getElementById("p2")!.firstChild!, 6);
    const selection = doc.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
    act(() => {
      doc.dispatchEvent(new doc.defaultView!.Event("pointerup", { bubbles: true }));
    });
    const button = chip(doc)!;
    expect(button).not.toBeNull();
    expect(button.dataset.hidden).toBeUndefined();
    const left = parseFloat(button.style.left);
    const top = parseFloat(button.style.top);
    const pill = { left, top, right: left + 72, bottom: top + 28 };
    // Every line's text, selected or not.
    for (const id of Object.keys(PARAGRAPH_LINES)) {
      const line = PARAGRAPH_LINES[id]!;
      const text = { left: 24, right: 24 + doc.getElementById(id)!.textContent!.length * 8, ...line };
      const crosses =
        Math.min(pill.right, text.right) - Math.max(pill.left, text.left) > 0.5 &&
        Math.min(pill.bottom, text.bottom) - Math.max(pill.top, text.top) > 0.5;
      expect({ id, crosses }).toEqual({ id, crosses: false });
    }
    // Over the selection's first line or under its last, not beside it.
    expect(pill.bottom <= PARAGRAPH_LINES.p1!.top || pill.top >= PARAGRAPH_LINES.p2!.bottom).toBe(true);
  } finally {
    restore();
  }
});

test("a row opening or closing above the selection moves the chip with its words, never over them", async () => {
  // Leo's 2026-11-21 05:30Z video: the chip was placed on pointerup, the click then opened a row
  // above, the words moved down under the chip and it stayed, covering them. Leo: "there are like 10
  // different extremely odd situations that go on here."
  // The transcript's own tree: the scroller's child is a spacer whose size need not change, and the
  // rows sit in the thread inside it.
  const doc = mount(
    `<div class="acpmux-scroll" style="overflow-y: auto"><div class="acpmux-spacer"><div class="acpmux-thread"><div class="acpmux-row" data-row-id="thought">Thinking</div>${PARAGRAPH}</div></div></div>`,
  );
  const view = doc.defaultView! as unknown as Record<string, unknown>;
  const observers: { fire: () => void; observed: Element[] }[] = [];
  view.ResizeObserver = class {
    observed: Element[] = [];
    constructor(callback: () => void) {
      observers.push({ fire: () => callback(), observed: this.observed });
    }
    observe(element: Element) {
      this.observed.push(element);
    }
    unobserve() {}
    disconnect() {
      this.observed.length = 0;
    }
  };
  const original = Object.fromEntries(Object.entries(PARAGRAPH_LINES).map(([id, line]) => [id, { ...line }]));
  const restore = layOutParagraph(doc);
  try {
    const range = doc.createRange();
    range.setStart(doc.getElementById("p2")!.firstChild!, 0);
    range.setEnd(doc.getElementById("p2")!.firstChild!, 6);
    doc.getSelection()!.removeAllRanges();
    doc.getSelection()!.addRange(range);
    act(() => {
      doc.dispatchEvent(new doc.defaultView!.Event("pointerup", { bubbles: true }));
    });
    const before = parseFloat(chip(doc)!.style.top);
    expect(Number.isFinite(before)).toBe(true);
    // The row above the selection is watched while the chip shows.
    const thought = doc.querySelector('[data-row-id="thought"]')!;
    expect(observers.some((o) => o.observed.includes(thought))).toBe(true);
    // So is a row the transcript mounts while the chip shows.
    const mounted = doc.createElement("div");
    mounted.className = "acpmux-row";
    mounted.dataset.rowId = "mounted";
    doc.querySelector(".acpmux-thread")!.prepend(mounted);
    await Promise.resolve();
    expect(observers.some((o) => o.observed.includes(mounted))).toBe(true);
    // A row above opens: every line moves 40 px down.
    for (const line of Object.values(PARAGRAPH_LINES)) {
      line.top += 40;
      line.bottom += 40;
    }
    // The thought row opened: only what watches it hears.
    act(() => observers.filter((o) => o.observed.includes(thought)).forEach((o) => o.fire()));
    const button = chip(doc)!;
    const top = parseFloat(button.style.top);
    expect(top).toBe(before + 40);
    const left = parseFloat(button.style.left);
    const pill = { left, top, right: left + 72, bottom: top + 28 };
    for (const id of Object.keys(PARAGRAPH_LINES)) {
      const line = PARAGRAPH_LINES[id]!;
      const text = { left: 24, right: 24 + doc.getElementById(id)!.textContent!.length * 8, ...line };
      const crosses =
        Math.min(pill.right, text.right) - Math.max(pill.left, text.left) > 0.5 &&
        Math.min(pill.bottom, text.bottom) - Math.max(pill.top, text.top) > 0.5;
      expect({ id, crosses }).toEqual({ id, crosses: false });
    }
  } finally {
    restore();
    for (const [id, line] of Object.entries(original)) Object.assign(PARAGRAPH_LINES[id]!, line);
    delete view.ResizeObserver;
  }
});
