// The minimap's preview card beside the hovered or focused mark: the prompt on one line with its
// bookmark, then the start of the reply. Both rails (ThreadMinimap.tsx, ScrollMap.tsx) draw it.
//
// The card draws in the transcript scroller's parent, not in the rail. The scroller masks its soft
// edges (conversation.css), and a masked ancestor is the card's backdrop root: inside it the blur
// had nothing under it to read, so the rows showed through the tint sharp (#23782). From the
// parent the card blurs the rows, as the chat's other glass does. An anchor left in the rail marks
// where the card's x and y count from, so it lands where it always did. The wheel over the card and
// a scrolling key on its bookmark still scroll the transcript, and reach the scroller's own
// listeners first (wheelPassThrough.ts), as they did when the card was inside it.
import React, { useCallback, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { forwardWheel } from "../wheelPassThrough";
import { BookmarkIcon } from "./BookmarkIcon";
import type { ReplyBlock } from "./model";

/// How far a key scrolls the transcript while focus is in it: a line, most of a page, or to an end.
function keyScroll(key: string, scroller: HTMLElement): number | undefined {
  const page = scroller.clientHeight * 0.875;
  if (key === "ArrowUp") return -40;
  if (key === "ArrowDown") return 40;
  if (key === "PageUp") return -page;
  if (key === "PageDown") return page;
  if (key === "Home") return -scroller.scrollTop;
  if (key === "End") return scroller.scrollHeight;
  return undefined;
}

/// A scrolling key on the card's bookmark (its one stop) scrolls the transcript, as it did when the
/// card drew inside it. The scroller gets a copy first, so its own key listeners run as for a key in
/// it (the scroll counts as the reader's, a jump in flight ends).
function forwardScrollKey(scroller: HTMLElement, event: React.KeyboardEvent): void {
  if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
  const by = keyScroll(event.key, scroller);
  if (by === undefined) return;
  event.preventDefault();
  scroller.dispatchEvent(new KeyboardEvent("keydown", { key: event.key, bubbles: false }));
  scroller.scrollTop += by;
}

export type PreviewBookmark = { marked: boolean; toggle(): void };

export const PreviewCard = React.forwardRef<
  HTMLDivElement,
  {
    id: string;
    /// From the rail's origin (`.acpmux-minimap`), wherever the card draws.
    x: number;
    y: number;
    /// The transcript scroller: the card draws in its parent, outside its mask. Without one the card
    /// draws in place.
    scroller?: HTMLElement | null;
    /// The prompt's line; a reply's card has none.
    prompt?: string;
    reply: readonly ReplyBlock[];
    bookmark?: PreviewBookmark;
    onPointerLeave(event: React.PointerEvent<HTMLDivElement>): void;
    onFocus?(): void;
    onBlur?(event: React.FocusEvent<HTMLDivElement>): void;
  }
>(function PreviewCard({ id, x, y, scroller, prompt, reply, bookmark, onPointerLeave, onFocus, onBlur }, ref) {
  const t = useT();
  const layer = scroller?.parentElement;
  const anchor = useRef<HTMLSpanElement>(null);
  const self = useRef<HTMLDivElement | null>(null);
  /// The rail's origin in the card's containing block, measured after each commit (before paint).
  const [origin, setOrigin] = useState({ x: 0, y: 0 });
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- runs after every commit on purpose (the rail can move under the card with any render); its setState is guarded by the comparison.
  useLayoutEffect(() => {
    const from = anchor.current;
    const node = self.current;
    if (!layer || !from || !node) return;
    const base = node.offsetParent instanceof HTMLElement ? node.offsetParent : layer;
    const mark = from.getBoundingClientRect();
    const frame = base.getBoundingClientRect();
    const next = {
      x: mark.left - frame.left - base.clientLeft + base.scrollLeft,
      y: mark.top - frame.top - base.clientTop + base.scrollTop,
    };
    if (next.x !== origin.x || next.y !== origin.y) setOrigin(next);
  });
  const own = useCallback(
    (node: HTMLDivElement | null) => {
      self.current = node;
      if (typeof ref === "function") ref(node);
      else if (ref) ref.current = node;
    },
    [ref],
  );
  const at = layer ? origin : { x: 0, y: 0 };
  const card = (
    <div
      ref={own}
      id={id}
      className="acpmux-minimap__card"
      style={{ transform: `translate3d(${at.x + x}px, ${at.y + y}px, 0)` }}
      onPointerLeave={onPointerLeave}
      onWheel={layer ? (event) => forwardWheel(scroller!, event.nativeEvent) : undefined}
      onFocus={onFocus}
      onBlur={onBlur}
    >
      {prompt !== undefined && (
        <div className="acpmux-minimap__title">
          <span className="acpmux-minimap__prompt">{prompt}</span>
          {bookmark && (
            <button
              type="button"
              className="acpmux-minimap__bookmark"
              aria-pressed={bookmark.marked}
              aria-label={t(bookmark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              title={t(bookmark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              onClick={bookmark.toggle}
              onKeyDown={layer ? (event) => forwardScrollKey(scroller!, event) : undefined}
            >
              <BookmarkIcon filled={bookmark.marked} />
            </button>
          )}
        </div>
      )}
      {reply.length > 0 && (
        <div className="acpmux-minimap__reply" data-only={prompt === undefined || undefined}>
          {reply.map((block, blockIndex) => (
            <p key={blockIndex} className={block.kind === "item" ? "acpmux-minimap__item" : undefined}>
              {block.spans.map((span, spanIndex) =>
                span.bold ? <strong key={spanIndex}>{span.text}</strong> : span.text,
              )}
            </p>
          ))}
        </div>
      )}
    </div>
  );
  if (!layer) return card;
  return (
    <>
      <span ref={anchor} className="acpmux-minimap__anchor" aria-hidden />
      {createPortal(card, layer)}
    </>
  );
});
