// The minimap's preview card beside the hovered or focused mark: the prompt on one line with its
// bookmark, then the start of the reply. Both rails (ThreadMinimap.tsx, ScrollMap.tsx) draw it.
//
// The card draws in `layer`, the transcript scroller's parent, not in the rail. The scroller masks
// its soft edges (conversation.css), and a masked ancestor is the card's backdrop root: inside it
// the blur had nothing under it to read, so the rows showed through the tint sharp (#23782). From
// the layer the card blurs the rows, as the chat's other glass does. An anchor left in the rail
// marks where the card's x and y count from, so it lands where it always did.
import React, { useCallback, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { BookmarkIcon } from "./BookmarkIcon";
import type { ReplyBlock } from "./model";

export type PreviewBookmark = { marked: boolean; toggle(): void };

export const PreviewCard = React.forwardRef<
  HTMLDivElement,
  {
    id: string;
    /// From the rail's origin (`.acpmux-minimap`), wherever the card draws.
    x: number;
    y: number;
    /// Where the card draws: outside every masked ancestor (the scroller's parent). Without one the
    /// card draws in place.
    layer?: HTMLElement | null;
    /// The prompt's line; a reply's card has none.
    prompt?: string;
    reply: readonly ReplyBlock[];
    bookmark?: PreviewBookmark;
    onPointerLeave(event: React.PointerEvent<HTMLDivElement>): void;
    onFocus?(): void;
    onBlur?(event: React.FocusEvent<HTMLDivElement>): void;
  }
>(function PreviewCard({ id, x, y, layer, prompt, reply, bookmark, onPointerLeave, onFocus, onBlur }, ref) {
  const t = useT();
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
