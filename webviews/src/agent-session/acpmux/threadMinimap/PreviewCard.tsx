// The minimap's preview card beside the hovered or focused mark: the prompt on one line with its
// bookmark, then the start of the reply. The rail (ThreadMinimap.tsx) draws it.
import React from "react";
import { useT } from "../i18n";
import { BookmarkIcon } from "./BookmarkIcon";
import type { ReplyBlock } from "./model";

export type PreviewBookmark = { marked: boolean; toggle(): void };

export const PreviewCard = React.forwardRef<
  HTMLDivElement,
  {
    id: string;
    x: number;
    y: number;
    /// The prompt's line; a reply's card has none.
    prompt?: string;
    reply: readonly ReplyBlock[];
    bookmark?: PreviewBookmark;
    onPointerLeave(event: React.PointerEvent<HTMLDivElement>): void;
    onFocus?(): void;
    onBlur?(event: React.FocusEvent<HTMLDivElement>): void;
  }
>(function PreviewCard({ id, x, y, prompt, reply, bookmark, onPointerLeave, onFocus, onBlur }, ref) {
  const t = useT();
  return (
    <div
      ref={ref}
      id={id}
      className="acpmux-minimap__card"
      style={{ transform: `translate3d(${x}px, ${y}px, 0)` }}
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
});
