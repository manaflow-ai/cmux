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
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { Quote } from "./icons";
import {
  useSelectionReplyLook,
  quoteInReply,
  type SelectionReplyTarget,
  selectionReplyTarget,
  PLACE_GAP,
  transcriptTextRects,
  selectionReplyPlace,
} from "./selectionReplyModel";
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
