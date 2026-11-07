// Reply to a part of a message: selecting transcript text shows a small Reply chip above the
// selection's end, as Claude and ChatGPT do, moved aside wherever that spot holds text (a "Sent to"
// line over the reply); clicking it quotes the selection into the composer,
// the same Quote in Reply the selection's right-click menu runs (AgentPaneContextMenu.swift
// `quote`, App.tsx `chat.quoteReply`). Leo, 2026-11-03: "would it make sense to have a direct
// reply button? or would you mostly just re-read your own thing anyways? what makes sense here?"
//
// The chip shows when a selection ends (pointer or key up), with no fade-in, and goes as soon as
// the selection collapses or leaves the transcript. It never shows for text in the composer (any
// editable field), in a code block (selected to copy) or in a read-only transcript. It does no
// work per token: it reads the DOM only on a selection's end and while it is shown.
//
// How it looks is a trial the theme can carry (`theme.selectionReply`, the gallery's
// agent-pane.selection-reply): `chip` (the default: quote glyph and "Reply"), `icon` (glyph only),
// `none` (the right-click menu alone) and `row` (a Reply button on every message's action row,
// kept to show why the chip won).
import { useCallback, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { Quote } from "./icons";

export type SelectionReplyLook = "chip" | "icon" | "none" | "row";
const LOOKS: readonly SelectionReplyLook[] = ["chip", "icon", "none", "row"];
let look: SelectionReplyLook = "chip";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the chip.
export function configureSelectionReply(value: unknown): void {
  const next = LOOKS.find((one) => one === value) ?? "chip";
  if (next === look) return;
  look = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => look;
export const useSelectionReplyLook = () => useSyncExternalStore(subscribe, current, current);

/// `text` as a Markdown quote with a blank line after it, as the right-click menu's Quote in Reply
/// makes it (AgentPaneContextMenu.swift `quote`).
export function quoteMarkdown(text: string): string {
  return `${text
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n")}\n\n`;
}

/// Where a quote goes: the pane's Quote in Reply (App.tsx), set while the pane is mounted.
let sink: ((markdown: string) => void) | undefined;
export function setQuoteReplySink(next: ((markdown: string) => void) | undefined): () => void {
  sink = next;
  return () => {
    if (sink === next) sink = undefined;
  };
}
export function quoteInReply(text: string): boolean {
  if (!sink || !text.trim()) return false;
  sink(quoteMarkdown(text));
  return true;
}

const EDITABLE = '[contenteditable]:not([contenteditable="false"]), textarea, input';
/// Text selected here is never offered the chip: the composer and fields, code blocks (selected to
/// copy; their own Copy is in the corner), a guest's read-only transcript and the chip itself.
const EXCLUDED = `${EDITABLE}, .cv-codeblock, pre, [data-read-only-transcript], .cv-selection-reply`;

const elementOf = (node: Node | null): Element | null =>
  node ? (node.nodeType === 1 ? (node as Element) : node.parentElement) : null;

export type SelectionReplyTarget = { text: string; left: number; top: number; bottom: number };

/// The selected transcript text and where its end is (viewport px), or undefined when the
/// selection is collapsed, blank, or not wholly in transcript messages.
export function selectionReplyTarget(doc: Document): SelectionReplyTarget | undefined {
  const selection = doc.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return undefined;
  for (const node of [selection.anchorNode, selection.focusNode]) {
    const element = elementOf(node);
    if (!element?.closest("[data-row-id]") || element.closest(EXCLUDED)) return undefined;
  }
  const text = selection.toString().trim();
  if (!text) return undefined;
  const range = selection.getRangeAt(0);
  const rects = Array.from(range.getClientRects?.() ?? []).filter((rect) => rect.width || rect.height);
  // A backward drag ends at the range's start: the chip goes where the pointer let go.
  const backward =
    selection.anchorNode !== null &&
    selection.focusNode !== null &&
    (selection.anchorNode === selection.focusNode
      ? selection.focusOffset < selection.anchorOffset
      : Boolean(selection.anchorNode.compareDocumentPosition(selection.focusNode) & 2));
  const rect = (backward ? rects[0] : rects[rects.length - 1]) ?? range.getBoundingClientRect?.();
  if (!rect) return { text, left: 0, top: 0, bottom: 0 };
  return { text, left: backward ? rect.left : rect.right, top: rect.top, bottom: rect.bottom };
}

export type PlaceRect = { left: number; top: number; right: number; bottom: number };
const PLACE_GAP = 6;

/// The boxes of the transcript's text in rows that cross `band` (viewport px, top to bottom): what
/// the chip must not cover. Read only when a chip is placed, and only for the rows near it.
export function transcriptTextRects(doc: Document, band: { top: number; bottom: number }): PlaceRect[] {
  const rects: PlaceRect[] = [];
  const range = doc.createRange();
  for (const row of Array.from(doc.querySelectorAll("[data-row-id]"))) {
    if (row.parentElement?.closest("[data-row-id]")) continue;
    const box = row.getBoundingClientRect();
    if (box.bottom < band.top || box.top > band.bottom) continue;
    const walker = doc.createTreeWalker(row, 4);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent?.trim()) continue;
      range.selectNodeContents(node);
      for (const rect of Array.from(range.getClientRects?.() ?? [])) {
        if (rect.width && rect.height && rect.bottom >= band.top && rect.top <= band.bottom) rects.push(rect);
      }
    }
  }
  return rects;
}

const overlap = (a: PlaceRect, b: PlaceRect) =>
  Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) *
  Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));

/// Where the chip goes: the first of these that covers no text, else the one covering least.
/// Above the selection's end and centred on it (as Claude and ChatGPT), then above but past the
/// text on that line, then on the end's own line past its text, then the same two below. The
/// chip never sits on a label or a line it does not belong to (Leo, 2026-11-05, on the chip drawn
/// over a "Sent to" line: "this is a bad reply").
export function selectionReplyPlace(
  target: SelectionReplyTarget,
  size: { width: number; height: number },
  pane: { width: number; height: number },
  text: readonly PlaceRect[],
): { left: number; top: number } {
  const { width, height } = size;
  const gap = PLACE_GAP;
  const centred = Math.max(gap, Math.min(target.left - width / 2, pane.width - width - gap));
  // Past every piece of text the chip's row would cross, or nowhere when that runs out of the pane.
  const after = (top: number, from: number) => {
    const right = text
      .filter((rect) => rect.bottom > top && rect.top < top + height)
      .reduce((most, rect) => Math.max(most, rect.right), from);
    const left = right + gap;
    return left + width + gap <= pane.width ? left : undefined;
  };
  const above = target.top - height - gap;
  const line = (target.top + target.bottom - height) / 2;
  const below = target.bottom + gap;
  const candidates: { left: number | undefined; top: number }[] = [
    { left: centred, top: above },
    { left: after(above, -Infinity), top: above },
    { left: after(line, target.left), top: line },
    { left: centred, top: below },
    { left: after(below, -Infinity), top: below },
  ];
  let best: { left: number; top: number; covered: number } | undefined;
  for (const { left, top } of candidates) {
    if (left === undefined || top < gap || (pane.height > 0 && top + height > pane.height - gap)) continue;
    const box = { left, top, right: left + width, bottom: top + height };
    const covered = text.reduce((sum, rect) => sum + overlap(box, rect), 0);
    if (covered === 0) return { left, top };
    if (!best || covered < best.covered) best = { left, top, covered };
  }
  return best ?? { left: centred, top: above >= gap ? above : below };
}

/// A Reply button for a message's action row (`row` look only), its glyph the row's 16 px
/// (MessageActions.tsx ROW_ICON).
export function RowReplyButton({ text }: { text: string }) {
  const t = useT();
  if (useSelectionReplyLook() !== "row" || !text) return null;
  const label = t("message.quoteReply");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-label={label}
      title={label}
      onClick={() => quoteInReply(text)}
    >
      <Quote size={16} />
    </button>
  );
}

/// The chip over the selection's end. Mounted once per pane (App.tsx), on the document's body.
export function SelectionReplyChip({ doc = document }: { doc?: Document }) {
  const t = useT();
  const current = useSelectionReplyLook();
  const enabled = current === "chip" || current === "icon";
  const [target, setTarget] = useState<SelectionReplyTarget>();
  const shown = useRef(false);
  shown.current = target !== undefined;
  const chip = useRef<HTMLButtonElement>(null);
  const [placed, setPlaced] = useState<{ left: number; top: number }>();

  useEffect(() => {
    if (!enabled) {
      setTarget(undefined);
      return;
    }
    const view = doc.defaultView;
    // A selection's end shows the chip: the pointer let go, or a Shift-arrow key came up.
    const ended = () => setTarget(selectionReplyTarget(doc));
    const keyUp = (event: KeyboardEvent) => {
      if (event.shiftKey || event.key === "Shift" || ((event.metaKey || event.ctrlKey) && event.key === "a")) ended();
    };
    // While shown, a collapsed or changed selection hides it now; it never shows mid-drag.
    const changed = () => {
      if (!shown.current) return;
      const next = selectionReplyTarget(doc);
      if (!next) setTarget(undefined);
    };
    const scrolled = () => {
      if (shown.current) setTarget(selectionReplyTarget(doc));
    };
    doc.addEventListener("pointerup", ended);
    doc.addEventListener("keyup", keyUp);
    doc.addEventListener("selectionchange", changed);
    view?.addEventListener("scroll", scrolled, true);
    view?.addEventListener("resize", scrolled);
    return () => {
      doc.removeEventListener("pointerup", ended);
      doc.removeEventListener("keyup", keyUp);
      doc.removeEventListener("selectionchange", changed);
      view?.removeEventListener("scroll", scrolled, true);
      view?.removeEventListener("resize", scrolled);
    };
  }, [doc, enabled]);

  // Where no transcript text is under it (selectionReplyPlace), read once per shown selection.
  useLayoutEffect(() => {
    if (!target) return setPlaced(undefined);
    const size = { width: chip.current?.offsetWidth ?? 0, height: chip.current?.offsetHeight ?? 0 };
    const pane = {
      width: doc.documentElement.clientWidth || doc.defaultView?.innerWidth || 0,
      height: doc.documentElement.clientHeight || doc.defaultView?.innerHeight || 0,
    };
    const band = { top: target.top - 2 * size.height - PLACE_GAP, bottom: target.bottom + 2 * size.height + PLACE_GAP };
    setPlaced(selectionReplyPlace(target, size, pane, transcriptTextRects(doc, band)));
  }, [doc, target]);

  const quote = useCallback(() => {
    if (!target) return;
    // Clear the transcript selection first: quoting focuses the composer with its caret under the
    // quote, and clearing after would take that caret too. A quote that fails gets its range back.
    const selection = doc.getSelection();
    const range = selection?.rangeCount ? selection.getRangeAt(0) : undefined;
    selection?.removeAllRanges();
    if (!quoteInReply(target.text) && range) selection?.addRange(range);
    setTarget(undefined);
  }, [doc, target]);

  if (!enabled || !target) return null;
  const label = t("message.quoteReply");
  return createPortal(
    <button
      ref={chip}
      type="button"
      className="cv-selection-reply"
      data-look={current}
      aria-label={label}
      title={current === "icon" ? label : undefined}
      style={placed ? { left: placed.left, top: placed.top } : { visibility: "hidden", left: 0, top: 0 }}
      // Pressing the chip keeps the selection it quotes.
      onPointerDown={(event) => event.preventDefault()}
      onMouseDown={(event) => event.preventDefault()}
      onClick={quote}
    >
      <Quote size={14} />
      {current === "chip" && <span>{label}</span>}
    </button>,
    doc.body,
  );
}
