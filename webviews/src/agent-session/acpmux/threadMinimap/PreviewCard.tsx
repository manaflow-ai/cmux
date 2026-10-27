// The minimap's preview card: an up-to-three-line prompt with its bookmark, recorded turn details and a
// four-line reply. Both rails (ThreadMinimap.tsx, ScrollMap.tsx) draw it.
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
import { Icon } from "../icons/Icon";
import { forwardWheel } from "../wheelPassThrough";
import { BookmarkIcon } from "./BookmarkIcon";
import type { MinimapTurnMetadata, ReplyBlock } from "./model";
import { useSenderIdentity } from "../subagents/subsessions";
import { SenderIdentityLabel } from "../SenderIdentityLabel";
import { PromptMarksSession } from "./promptMarks";

const middleEllipsis = (value: string, max = 36) => {
  if (value.length <= max) return value;
  const side = Math.max(4, Math.floor((max - 1) / 2));
  return `${value.slice(0, side)}…${value.slice(-side)}`;
};

const linkLabel = (href: string) => {
  const match = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(href);
  return match ? `${match[1]}/${match[2]}#${match[3]}` : href;
};

const timeLabel = (at: number) =>
  new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(new Date(at));

// Only bounded preview spans pass here. Preserve both ends of hashes, paths and URLs; the full
// token stays available to hover and assistive technology instead of taking over the whole card.
const previewText = (value: string) =>
  value.split(/(\S{40,})/).map((token, index) =>
    index % 2 === 1 && /[/.\\]|^[a-f\d]+$/i.test(token) ? (
      <span key={index} title={token}>
        <span aria-hidden="true">{middleEllipsis(token)}</span>
        <span className="acpmux-minimap__full-token">{token}</span>
      </span>
    ) : (
      token
    ),
  );

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

/// A scrolling key on any card control scrolls the transcript, as when the card drew inside it.
/// The scroller gets a copy first, so its own key listeners run as for a key in
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
    metadata?: MinimapTurnMetadata;
    /// The rail's unshifted left edge, for the same pane-edge clamp in both CSS translations.
    railLeft?: number;
    bookmark?: PreviewBookmark;
    onPointerLeave(event: React.PointerEvent<HTMLDivElement>): void;
    onSizeChange?(): void;
    onFocus?(): void;
    onBlur?(event: React.FocusEvent<HTMLDivElement>): void;
  }
>(function PreviewCard(
  {
    id,
    x,
    y,
    scroller,
    prompt,
    reply,
    metadata,
    railLeft = 0,
    bookmark,
    onPointerLeave,
    onSizeChange,
    onFocus,
    onBlur,
  },
  ref,
) {
  const t = useT();
  const layer = scroller?.parentElement;
  const anchor = useRef<HTMLSpanElement>(null);
  const self = useRef<HTMLDivElement | null>(null);
  const onSizeChangeRef = useRef(onSizeChange);
  onSizeChangeRef.current = onSizeChange;
  /// The rail's origin in the card's containing block, measured after each commit (before paint).
  const [origin, setOrigin] = useState({ x: 0, y: 0 });
  const [replyMetrics, setReplyMetrics] = useState({ lines: 1, lineHeight: 20 });
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- runs after every commit on purpose (the rail can move under the card with any render); its setState is guarded by the comparison.
  useLayoutEffect(() => {
    const from = anchor.current;
    const node = self.current;
    if (!layer || !from || !node) return;
    const base = node.offsetParent instanceof HTMLElement ? node.offsetParent : layer;
    const mark = from.getBoundingClientRect();
    const frame = base.getBoundingClientRect();
    const shiftX =
      Number.parseFloat(from.ownerDocument.defaultView?.getComputedStyle(from.parentElement!).translate ?? "") || 0;
    const next = {
      x: mark.left - shiftX - frame.left - base.clientLeft + base.scrollLeft,
      y: mark.top - frame.top - base.clientTop + base.scrollTop,
    };
    if (next.x !== origin.x || next.y !== origin.y) setOrigin(next);
  });
  // The text budget is six lines: the old two-line prompt plus four-line reply. Measure the
  // prompt's actual wrapped lines when the card opens (and when its width changes), then give the
  // reply the remaining whole lines. Metadata and failure details keep their old natural rows.
  useLayoutEffect(() => {
    const node = self.current;
    if (!node || prompt === undefined) return;
    const update = () => {
      const promptNode = node.querySelector<HTMLElement>(".acpmux-minimap__prompt");
      const replyNode = node.querySelector<HTMLElement>(".acpmux-minimap__reply");
      if (!promptNode || !replyNode) return;
      const style = promptNode.ownerDocument.defaultView?.getComputedStyle(promptNode);
      if (!style) return;
      const lineHeight = Number.parseFloat(style.lineHeight) || 20;
      const promptLines = Math.max(1, Math.min(3, Math.ceil(promptNode.getBoundingClientRect().height / lineHeight)));
      const naturalReply = replyNode.cloneNode(true) as HTMLElement;
      naturalReply.style.cssText =
        "position:absolute; visibility:hidden; display:block; height:auto; max-height:none; -webkit-line-clamp:unset;";
      naturalReply.style.width = `${replyNode.getBoundingClientRect().width}px`;
      node.append(naturalReply);
      const naturalReplyLines = Math.max(
        1,
        Math.min(4, Math.ceil(naturalReply.getBoundingClientRect().height / lineHeight)),
      );
      naturalReply.remove();
      // Match the old two-line prompt + four-line reply text budget for this same content. A
      // longer prompt spends only the reply lines it needs, so the card never grows because of it.
      const oldTextLines = Math.min(2, promptLines) + naturalReplyLines;
      const lines = Math.max(1, Math.min(4, oldTextLines - promptLines));
      setReplyMetrics((previous) =>
        previous.lines === lines && Math.abs(previous.lineHeight - lineHeight) < 0.1 ? previous : { lines, lineHeight },
      );
      onSizeChangeRef.current?.();
    };
    update();
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(update);
    observer?.observe(node);
    return () => observer?.disconnect();
  }, [metadata?.failure, metadata?.failed, prompt, reply]);
  const own = useCallback(
    (node: HTMLDivElement | null) => {
      self.current = node;
      if (typeof ref === "function") ref(node);
      else if (ref) ref.current = node;
    },
    [ref],
  );
  const at = layer ? origin : { x: 0, y: 0 };
  const scrollKey = layer ? (event: React.KeyboardEvent) => forwardScrollKey(scroller!, event) : undefined;
  const card = (
    <div
      ref={own}
      id={id}
      className="acpmux-minimap__card"
      data-prompt={prompt !== undefined ? "" : undefined}
      style={
        {
          "--acpmux-rail-left": `${railLeft}px`,
          transform: `translate3d(${at.x + x}px, ${at.y + y}px, 0)`,
        } as React.CSSProperties
      }
      onPointerLeave={onPointerLeave}
      onWheel={layer ? (event) => forwardWheel(scroller!, event.nativeEvent) : undefined}
      onFocus={onFocus}
      onBlur={onBlur}
    >
      {prompt !== undefined && (
        <div className="acpmux-minimap__title">
          <span className="acpmux-minimap__prompt">
            {metadata?.sender && <PreviewSender sender={metadata.sender} />}
            {prompt}
          </span>
          {bookmark && (
            <button
              type="button"
              className="acpmux-minimap__bookmark"
              aria-pressed={bookmark.marked}
              aria-label={t(bookmark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              title={t(bookmark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              onClick={bookmark.toggle}
              onKeyDown={scrollKey}
            >
              <BookmarkIcon filled={bookmark.marked} />
            </button>
          )}
        </div>
      )}
      {metadata && (
        <div className="acpmux-minimap__metadata" aria-label={t("minimap.label")}>
          <span className="acpmux-minimap__meta-token" data-meta="time">
            {timeLabel(metadata.at)}
          </span>
          {metadata.durationMs !== undefined && (
            <span className="acpmux-minimap__meta-token" data-meta="duration">
              {t("duration.s", { n: Math.max(0, Math.round(metadata.durationMs / 1000)) })}
            </span>
          )}
          {metadata.toolCount !== undefined && metadata.toolCount > 0 && (
            <span className="acpmux-minimap__meta-token" data-meta="tools">
              {metadata.toolCount === 1 ? t("toolRun.used.one") : t("toolRun.used.other", { n: metadata.toolCount })}
            </span>
          )}
          {metadata.fileCount !== undefined && (
            <span className="acpmux-minimap__meta-token" data-meta="files">
              {metadata.fileCount === 1
                ? t("toolRun.edited.one")
                : t("toolRun.edited.other", { n: metadata.fileCount })}
            </span>
          )}
          {metadata.links.map((href) => (
            <a
              key={href}
              className="acpmux-minimap__meta-link"
              data-meta="pr"
              href={href}
              rel="noreferrer"
              target="_blank"
              title={href}
              onKeyDown={scrollKey}
            >
              {middleEllipsis(linkLabel(href))}
            </a>
          ))}
        </div>
      )}
      {(metadata?.failure || metadata?.failed) && (
        <div className="acpmux-minimap__failure" data-failure="true">
          <Icon name="status.error" size={14} className="acpmux-minimap__failure-icon" />
          <span>{metadata.failure || t("turn.failed")}</span>
        </div>
      )}
      {reply.length > 0 && (
        <div
          className="acpmux-minimap__reply"
          data-only={prompt === undefined || undefined}
          style={
            prompt === undefined
              ? undefined
              : ({
                  "--acpmux-minimap-reply-lines": replyMetrics.lines,
                  "--acpmux-minimap-reply-line-height": `${replyMetrics.lineHeight}px`,
                } as React.CSSProperties)
          }
        >
          {reply.map((block, blockIndex) => (
            <p key={blockIndex} className={block.kind === "item" ? "acpmux-minimap__item" : undefined}>
              {block.spans.map((span, spanIndex) =>
                span.code ? (
                  <code key={spanIndex}>{previewText(span.text)}</code>
                ) : span.bold ? (
                  <strong key={spanIndex}>{previewText(span.text)}</strong>
                ) : (
                  <React.Fragment key={spanIndex}>{previewText(span.text)}</React.Fragment>
                ),
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

function PreviewSender({ sender }: { sender: NonNullable<MinimapTurnMetadata["sender"]> }) {
  const identity = useSenderIdentity(sender, React.useContext(PromptMarksSession));
  return (
    <>
      <SenderIdentityLabel identity={identity} />
      {" · "}
    </>
  );
}
