// The minimap's preview card: the prompt as a one-line title with its bookmark, recorded turn details
// and the reply's first lines under it in regular weight, as wide as its words up to the arm's widest
// (card.experiment.ts). The pointer moving from the rail into the card opens it to more of the reply
// (Leo, 2026-11-07: "if you, you know, you're in the rail, and then you hover over to the right,
// perhaps you can expand"). Both rails (ThreadMinimap.tsx, ScrollMap.tsx) draw it.
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
import { CARD_LOOK, threadMinimapCard } from "./card.experiment";
import { cardOffset, EDGE_MARGIN, type MinimapTurnMetadata, type ReplyBlock } from "./model";
import { experimentArm } from "../../../experiments/experiment";
import { Button } from "../../../ui/Button";
import { sliceWhole, sliceWholeEnd } from "../../../ui/wholeChars";
import { type CoveredCandidates, useSeeThroughBlur } from "../../../ui/glass/seeThroughBlur";
import { useSenderIdentity } from "../subagents/subsessions";
import { SenderIdentityLabel } from "../SenderIdentityLabel";
import { PromptMarksSession } from "./promptMarks";

const middleEllipsis = (value: string, max = 36) => {
  if (value.length <= max) return value;
  const side = Math.max(4, Math.floor((max - 1) / 2));
  return `${sliceWhole(value, side)}…${sliceWholeEnd(value, side)}`;
};

const linkLabel = (href: string) => {
  const match = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(href);
  return match ? `${match[1]}/${match[2]}#${match[3]}` : href;
};

/// One formatter for every card: building an Intl.DateTimeFormat costs far more than formatting with
/// one, and the card renders again for each row the pointer (or a wheel under it) passes.
let timeFormat: Intl.DateTimeFormat | undefined;
const timeLabel = (at: number) =>
  (timeFormat ??= new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
  })).format(new Date(at));

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

/// What the card covers when it draws in the scroller's parent: the transcript scroller alone, never
/// the rail or a Find bar beside it. In a see-through Chromium page the card's backdrop blur draws
/// over the rows, not in their place, so they read sharp through its tint (Lawrence via Leo,
/// 2026-10-28: "popovers in general need glassier bg blur"); the scroller blurs its own rows under
/// the card instead (ui/glass/seeThroughBlur.ts). In place (no layer) the card is inside the
/// scroller and covers nothing.
const underCard: CoveredCandidates = (surface) =>
  surface.parentElement?.querySelectorAll(":scope > .acpmux-scroll") ?? [];

/// Whether the wheel over `target` scrolls the open card's reply itself: it is inside the reply, and
/// the reply has more to scroll that way. Otherwise the wheel goes on to the transcript.
function replyScrolls(target: EventTarget | null, deltaY: number): boolean {
  const reply = target instanceof Element ? target.closest<HTMLElement>(".acpmux-minimap__reply") : null;
  if (!reply || !reply.closest(".acpmux-minimap__card[data-open]")) return false;
  if (deltaY < 0) return reply.scrollTop > 0;
  return reply.scrollTop + reply.clientHeight < reply.scrollHeight - 1;
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
    /// The prompt is not loaded yet (a pending tick, model.ts `pendingTurns`): the card holds a blank
    /// line where its words go, and they fade in there when they arrive.
    pending?: boolean;
    /// The rail row the card is open on: the fade of arriving words is this row's, never replayed on
    /// the row the card moves to.
    row?: number;
    /// The prompt's sender, when another session sent it (model.ts `promptSender`): a line above it
    /// names them, so it never reads as the person's own words.
    from?: string;
    reply: readonly ReplyBlock[];
    /// More of the reply, for the card opened by the pointer moving into it (model.ts `replyMore`):
    /// asked for only then, so a sweep over the rail reads none of it.
    more?(): readonly ReplyBlock[];
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
    pending = false,
    row,
    from,
    reply,
    more,
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
  /// The reply's lines, at first and once the pointer moves into the card, and the card's widest, as
  /// the hover-card experiment's arm sets them (card.experiment.ts), read once per card.
  const [look] = useState(() => CARD_LOOK[experimentArm(threadMinimapCard)]);
  const layer = scroller?.parentElement;
  /// The words of a prompt that was pending under the open card arrived: they fade in (opacity only,
  /// threadMinimap.css `[data-arrived]`), in the place the blank line held. Set before paint.
  const [arrived, setArrived] = useState(false);
  const wasPending = useRef(pending);
  const wasRow = useRef(row);
  useLayoutEffect(() => {
    if (wasRow.current !== row) setArrived(false);
    else if (wasPending.current && !pending) setArrived(true);
    else if (pending) setArrived(false);
    wasPending.current = pending;
    wasRow.current = row;
  }, [pending, row]);
  const anchor = useRef<HTMLSpanElement>(null);
  const self = useRef<HTMLDivElement | null>(null);
  /// Where the card goes, as of the last render: read by `place`, which a commit or a resize runs.
  const at = useRef({ x, center, viewportHeight, layer, side });
  at.current = { x, center, viewportHeight, layer, side };
  /// Where the card's row is: the rail's origin in the card's containing block (none without a
  /// layer). Reads only: the anchor and the layer, never the card's own size, so it shares one layout
  /// with the fit's reads.
  const origin = useCallback((node: HTMLElement) => {
    const into = at.current.layer;
    const from = anchor.current;
    if (!into || !from) return { x: 0, y: 0 };
    const base = node.offsetParent instanceof HTMLElement ? node.offsetParent : into;
    const mark = from.getBoundingClientRect();
    const frame = base.getBoundingClientRect();
    const shiftX =
      Number.parseFloat(from.ownerDocument.defaultView?.getComputedStyle(from.parentElement!).translate ?? "") || 0;
    return {
      x: mark.left - shiftX - frame.left - base.clientLeft + base.scrollLeft,
      y: mark.top - frame.top - base.clientTop + base.scrollTop,
    };
  }, []);
  /// The card's top as `move` last wrote it, and where an open card keeps its top (`open`): it grows
  /// down from where it was, under the pointer, never re-centering on its row, and moves up only as
  /// far as the view's foot makes it. A card for another row centers again.
  const lastTop = useRef(0);
  const openTop = useRef<number | undefined>(undefined);
  /// Writes the card's transform: `from` (the rail's origin, `origin`) plus `x`, and its `height`
  /// centered on `center` inside the viewport. Writes only.
  const move = useCallback((node: HTMLElement, from: { x: number; y: number }, height: number) => {
    const { x: inset, center: middle, viewportHeight: room, layer: into, side: edge } = at.current;
    const held = openTop.current;
    const top =
      held === undefined
        ? cardOffset(middle, height, room)
        : Math.max(EDGE_MARGIN, Math.min(held, room - EDGE_MARGIN - height));
    lastTop.current = top;
    // On the left the card starts `inset` past the rail's origin (card.left == rail.right). On the
    // right the origin is the pane's right edge and the card ends `inset` in from it (card.right ==
    // rail.left): placed in the layer by its own width, or pinned to the right edge without one.
    const transform =
      edge === "left"
        ? `translate3d(${from.x + inset}px, ${from.y + top}px, 0)`
        : into
          ? `translate3d(${from.x - inset}px, ${from.y + top}px, 0) translateX(-100%)`
          : `translate3d(${-inset}px, ${top}px, 0)`;
    if (node.style.transform !== transform) node.style.transform = transform;
  }, []);
  /// The card's height as of its last place: a resize notification of that height (the observer's
  /// first) places nothing again.
  const placedHeight = useRef(-1);
  /// Puts the card beside its row. It writes the transform itself, before paint, with no state: a
  /// card that opens, follows the pointer to another row or grows renders once, and lays out once for
  /// the reads here (#28540: an origin and a height held in state took three commits and six forced
  /// layouts to open a card). Every read comes before the one write.
  ///
  /// The card's size is CSS's alone: a one-line title and the reply clamped to the arm's lines
  /// (threadMinimap.css), so nothing here measures the text. A sweep's row reads once (the rail's
  /// origin and the card's height, one layout) and writes the transform: the measuring passes the
  /// three-line prompt needed, which shared its lines with the reply, are gone (Leo, 2026-11-04:
  /// "hovering across the session rail gets a bit laggy ... it needs to get faster").
  const place = useCallback(() => {
    const node = self.current;
    if (!node) return;
    const from = origin(node);
    const height = node.offsetHeight;
    move(node, from, height);
    placedHeight.current = height;
  }, [origin, move]);
  /// The pointer moved from the rail into the card: it opens to more of the reply (`more`), growing
  /// down from where it is (`openTop`). It closes again when the pointer leaves, and a card for another
  /// row starts closed.
  const [open, setOpen] = useState(false);
  const openRow = useRef(row);
  if (openRow.current !== row) {
    openRow.current = row;
    if (open) setOpen(false);
  }
  /// The content the card was last placed for: a card for another row centers again on its row.
  const placedFor = useRef<readonly unknown[]>([]);
  // After every commit on purpose: the rail can move under the card with any render.
  useLayoutEffect(() => {
    const node = self.current;
    if (!node) return;
    const now = [metadata?.failure, metadata?.failed, prompt, from, reply, row];
    if (
      now.length !== placedFor.current.length ||
      !now.every((value, index) => Object.is(value, placedFor.current[index]))
    ) {
      placedFor.current = now;
      openTop.current = undefined;
    }
    place();
  });
  // After the card is placed, so the blur's first measure finds it where it draws.
  useSeeThroughBlur(self, !!layer, underCard);
  // Content that grows or shrinks without a render (a font loading, a wrap, the card opening over
  // its transition) places it again. One observer for the card's life, not one per row the pointer
  // crosses (each new one notifies on observe). It stops with the card: disconnected in the cleanup
  // when the card goes.
  useLayoutEffect(() => {
    const node = self.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (node.offsetHeight === placedHeight.current) return;
      place();
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [place]);
  const promptCard = prompt !== undefined && !pending;
  const canOpen = promptCard && reply.length > 0;
  const openCard = () => {
    if (!canOpen || open) return;
    // Grows down from where it is now: the title stays under the pointer.
    openTop.current = lastTop.current;
    setOpen(true);
  };
  const shown = open && more ? more() : reply;
  const own = useCallback(
    (node: HTMLDivElement | null) => {
      self.current = node;
      if (typeof ref === "function") ref(node);
      else if (ref) ref.current = node;
    },
    [ref],
  );
  const scrollKey = layer ? (event: React.KeyboardEvent) => forwardScrollKey(scroller!, event) : undefined;
  const { width: widest, lines, open: openLines } = look;
  const cardStyle: React.CSSProperties & Record<`--${string}`, string> = {
    "--acpmux-rail-left": `${railLeft}px`,
    "--acpmux-minimap-card-max": `${widest}px`,
    "--acpmux-minimap-reply-lines": String(lines),
    "--acpmux-minimap-reply-open-lines": String(openLines),
    ...(side === "right" && !layer ? { left: "auto", right: 0 } : {}),
  };
  const card = (
    <div
      ref={own}
      id={id}
      className="acpmux-minimap__card"
      data-prompt={prompt !== undefined ? "" : undefined}
      data-incoming={from !== undefined || undefined}
      data-pending={pending || undefined}
      data-arrived={arrived || undefined}
      data-open={(open && canOpen) || undefined}
      aria-busy={pending || undefined}
      // Its transform is `place`'s, written before paint; on the right with no layer it is pinned to
      // the right edge (left: auto; right: 0) and `place` counts `x` in from there.
      style={cardStyle}
      onPointerEnter={() => {
        openCard();
        onPointerEnter?.();
      }}
      onPointerLeave={(event) => {
        setOpen(false);
        onPointerLeave(event);
      }}
      onWheel={
        layer
          ? (event) => {
              // An open card's reply scrolls itself while it has more that way; past its end the
              // wheel scrolls the transcript, as over the rest of the card.
              if (replyScrolls(event.target, event.deltaY)) return;
              forwardWheel(scroller!, event.nativeEvent);
            }
          : undefined
      }
      onFocus={onFocus}
      onBlur={onBlur}
    >
      {prompt !== undefined && from !== undefined && (
        <div className="acpmux-minimap__from">
          {/* One sender the turn records reads as its session (senderIdentity.ts); a run of several,
              or a sender no session list or id names, keeps "From <name>". */}
          {metadata?.sender && metadata.sender.name === from ? (
            <PreviewSender sender={metadata.sender} fallback={t("minimap.from", { name: from })} />
          ) : (
            t("minimap.from", { name: from })
          )}
        </div>
      )}
      {prompt !== undefined && (
        <div className="acpmux-minimap__title">
          {pending ? (
            <span className="acpmux-minimap__prompt" data-pending="" aria-hidden />
          ) : (
            <span className="acpmux-minimap__prompt">{prompt}</span>
          )}
          {bookmark && (
            <Button
              variant="ghost"
              size="sm"
              icon
              className="acpmux-minimap__bookmark"
              aria-pressed={bookmark.marked}
              aria-label={t(bookmark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              title={t(bookmark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              onClick={bookmark.toggle}
              onKeyDown={scrollKey}
            >
              <BookmarkIcon filled={bookmark.marked} />
            </Button>
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
          {shown.map((block, blockIndex) => (
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

function PreviewSender({ sender, fallback }: { sender: NonNullable<MinimapTurnMetadata["sender"]>; fallback: string }) {
  const identity = useSenderIdentity(sender, React.useContext(PromptMarksSession));
  return identity.known ? <SenderIdentityLabel identity={identity} /> : <>{fallback}</>;
}
