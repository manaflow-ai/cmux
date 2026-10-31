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
import React, { useCallback, useLayoutEffect, useRef } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { forwardWheel } from "../wheelPassThrough";
import { BookmarkIcon } from "./BookmarkIcon";
import { cardOffset, type MinimapTurnMetadata, type ReplyBlock } from "./model";

const middleEllipsis = (value: string, max = 36) => {
  if (value.length <= max) return value;
  const side = Math.max(4, Math.floor((max - 1) / 2));
  return `${value.slice(0, side)}…${value.slice(-side)}`;
};

const linkLabel = (href: string) => {
  const match = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(href);
  return match ? `${match[1]}/${match[2]}#${match[3]}` : href;
};

/// One formatter for every card: building an Intl.DateTimeFormat costs far more than formatting with
/// one, and the card renders again for each row the pointer (or a wheel under it) passes.
let timeFormat: Intl.DateTimeFormat | undefined;
const timeLabel = (at: number) =>
  (timeFormat ??= new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })).format(new Date(at));

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
    /// Where the card centers itself (from the rail's origin), kept inside `viewportHeight` with its
    /// own height (model.ts cardOffset). The card measures that height itself, so its owner holds no
    /// height state and a card that opens or changes renders once.
    center: number;
    viewportHeight: number;
    /// The transcript scroller: the card draws in its parent, outside its mask. Without one the card
    /// draws in place.
    scroller?: HTMLElement | null;
    /// The prompt's line; a reply's card has none.
    prompt?: string;
    reply: readonly ReplyBlock[];
    metadata?: MinimapTurnMetadata;
    /// The rail's unshifted left edge, for the same pane-edge clamp in both CSS translations.
    railLeft?: number;
    /// The rail's edge of the pane (railSide.ts). On the right, `x` counts in from the pane's right
    /// edge and the card opens to its left, so card.right == rail.left.
    side?: "left" | "right";
    bookmark?: PreviewBookmark;
    onPointerEnter?(): void;
    onPointerLeave(event: React.PointerEvent<HTMLDivElement>): void;
    onFocus?(): void;
    onBlur?(event: React.FocusEvent<HTMLDivElement>): void;
  }
>(function PreviewCard(
  {
    id,
    x,
    center,
    viewportHeight,
    scroller,
    prompt,
    reply,
    metadata,
    railLeft = 0,
    side = "left",
    bookmark,
    onPointerEnter,
    onPointerLeave,
    onFocus,
    onBlur,
  },
  ref,
) {
  const t = useT();
  const layer = scroller?.parentElement;
  const anchor = useRef<HTMLSpanElement>(null);
  const self = useRef<HTMLDivElement | null>(null);
  /// Where the card goes, as of the last render: read by `place`, which a commit or a resize runs.
  const at = useRef({ x, center, viewportHeight, layer, side });
  at.current = { x, center, viewportHeight, layer, side };
  /// Puts the card beside its row: the rail's origin in the card's containing block (none without a
  /// layer), plus `x`, and its own height centered on `center` inside the viewport. It writes the
  /// transform itself, before paint, with no state: a card that opens, follows the pointer to another
  /// row or grows renders once, and lays out once for the reads here (#28540: an origin and a height
  /// held in state took three commits and six forced layouts to open a card).
  const place = useCallback(() => {
    const node = self.current;
    if (!node) return;
    const { x: inset, center: middle, viewportHeight: room, layer: into, side: edge } = at.current;
    let origin = { x: 0, y: 0 };
    const from = anchor.current;
    if (into && from) {
      const base = node.offsetParent instanceof HTMLElement ? node.offsetParent : into;
      const mark = from.getBoundingClientRect();
      const frame = base.getBoundingClientRect();
      const shiftX =
        Number.parseFloat(from.ownerDocument.defaultView?.getComputedStyle(from.parentElement!).translate ?? "") || 0;
      origin = {
        x: mark.left - shiftX - frame.left - base.clientLeft + base.scrollLeft,
        y: mark.top - frame.top - base.clientTop + base.scrollTop,
      };
    }
    const top = cardOffset(middle, node.offsetHeight, room);
    // On the left the card starts `inset` past the rail's origin (card.left == rail.right). On the
    // right the origin is the pane's right edge and the card ends `inset` in from it (card.right ==
    // rail.left): placed in the layer by its own width, or pinned to the right edge without one.
    const transform =
      edge === "left"
        ? `translate3d(${origin.x + inset}px, ${origin.y + top}px, 0)`
        : into
          ? `translate3d(${origin.x - inset}px, ${origin.y + top}px, 0) translateX(-100%)`
          : `translate3d(${-inset}px, ${top}px, 0)`;
    if (node.style.transform !== transform) node.style.transform = transform;
  }, []);
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- runs after every commit on purpose: the rail can move under the card with any render.
  useLayoutEffect(() => place());
  // The text budget is six lines: the old two-line prompt plus four-line reply. Measure the
  // prompt's actual wrapped lines when the card opens (and when its width changes), then give the
  // reply the remaining whole lines. Metadata and failure details keep their old natural rows.
  /// Sets the reply's line budget for this card's kind, in place (no state: it changes no React
  /// output), then places the card by its height after that change. Every card kind takes this one
  /// path, at open and on every resize, so a card reused for another kind (a prompt's card, then a
  /// reply's) is measured after its clamp changed, never before (#28540 review).
  const fit = useCallback(
    (node: HTMLElement, promptCard: boolean) => {
      const replyNode = node.querySelector<HTMLElement>(".acpmux-minimap__reply");
      const promptNode = node.querySelector<HTMLElement>(".acpmux-minimap__prompt");
      const style = promptNode?.ownerDocument.defaultView?.getComputedStyle(promptNode);
      if (!promptCard || !replyNode || !promptNode || !style) {
        // A reply's card takes the reply's own clamp (data-only): no prompt card's budget.
        replyNode?.style.removeProperty("--acpmux-minimap-reply-lines");
        replyNode?.style.removeProperty("--acpmux-minimap-reply-line-height");
      } else {
        const lineHeight = Number.parseFloat(style.lineHeight) || 20;
        const promptLines = Math.max(1, Math.min(3, Math.ceil(promptNode.getBoundingClientRect().height / lineHeight)));
        // The reply's natural height, read from the reply itself with its clamp lifted for the read
        // (an inline style, put back before anything paints). A measuring copy appended to the card
        // and removed again was two DOM insertions under the page's `:has()` rules on every row the
        // pointer crossed, and each restyled the whole page (about 1,100 elements) twice per move.
        const clamp = replyNode.getAttribute("style");
        replyNode.style.setProperty("display", "block");
        replyNode.style.setProperty("height", "auto");
        replyNode.style.setProperty("max-height", "none");
        replyNode.style.setProperty("-webkit-line-clamp", "unset");
        const naturalReplyLines = Math.max(
          1,
          Math.min(4, Math.ceil(replyNode.getBoundingClientRect().height / lineHeight)),
        );
        if (clamp === null) replyNode.removeAttribute("style");
        else replyNode.setAttribute("style", clamp);
        // Match the old two-line prompt + four-line reply text budget for this same content. A
        // longer prompt spends only the reply lines it needs, so the card never grows because of it.
        const oldTextLines = Math.min(2, promptLines) + naturalReplyLines;
        const lines = Math.max(1, Math.min(4, oldTextLines - promptLines));
        replyNode.style.setProperty("--acpmux-minimap-reply-lines", String(lines));
        replyNode.style.setProperty("--acpmux-minimap-reply-line-height", `${lineHeight}px`);
      }
      // The budget sets the card's height, and with it where the card centers.
      place();
    },
    [place],
  );
  /// The card's kind as of the last render, for the observer below, which outlives a content change.
  const promptCard = useRef(prompt !== undefined);
  promptCard.current = prompt !== undefined;
  /// The card's size as of its last fit: a resize notification of that size (the observer's first,
  /// or the one the fit's own budget change causes) fits nothing again.
  const fitted = useRef({ width: -1, height: -1 });
  const refit = useCallback(
    (node: HTMLElement) => {
      fit(node, promptCard.current);
      // Laid out by the fit's own reads: these read no new layout.
      fitted.current = { width: node.offsetWidth, height: node.offsetHeight };
    },
    [fit],
  );
  // A new prompt, reply or failure (the pointer reaching another row), or a change of kind: fit once.
  useLayoutEffect(() => {
    if (self.current) refit(self.current);
  }, [metadata?.failure, metadata?.failed, prompt, reply, refit]);
  // Content that grows or shrinks without a render (a font or an image loading, a wrap) fits again.
  // One observer for the card's life, not one per row the pointer crosses (each new one notifies on
  // observe, which fitted the card a second time per move). It stops with the card: disconnected in
  // the cleanup when the card goes.
  useLayoutEffect(() => {
    const node = self.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (node.offsetWidth === fitted.current.width && node.offsetHeight === fitted.current.height) return;
      refit(node);
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [refit]);
  const own = useCallback(
    (node: HTMLDivElement | null) => {
      self.current = node;
      if (typeof ref === "function") ref(node);
      else if (ref) ref.current = node;
    },
    [ref],
  );
  const scrollKey = layer ? (event: React.KeyboardEvent) => forwardScrollKey(scroller!, event) : undefined;
  const cardStyle: React.CSSProperties & { "--acpmux-rail-left": string } = {
    "--acpmux-rail-left": `${railLeft}px`,
    ...(side === "right" && !layer ? { left: "auto", right: 0 } : {}),
  };
  const card = (
    <div
      ref={own}
      id={id}
      className="acpmux-minimap__card"
      data-prompt={prompt !== undefined ? "" : undefined}
      // Its transform is `place`'s, written before paint; on the right with no layer it is pinned to
      // the right edge (left: auto; right: 0) and `place` counts `x` in from there.
      style={cardStyle}
      onPointerEnter={onPointerEnter}
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
        <div className="acpmux-minimap__reply" data-only={prompt === undefined || undefined}>
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
      <span
        ref={anchor}
        className="acpmux-minimap__anchor"
        style={side === "right" ? { left: "auto", right: 0 } : undefined}
        aria-hidden
      />
      {createPortal(card, layer)}
    </>
  );
});
