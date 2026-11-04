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
import { cardOffset, type MinimapTurnMetadata, type ReplyBlock } from "./model";
import { Button } from "../../../ui/Button";
import { sliceWhole, sliceWholeEnd } from "../../../ui/wholeChars";
import { type CoveredCandidates, useSeeThroughBlur } from "../../../ui/glass/seeThroughBlur";

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

/// A prompt card's measured text budget: the reply's lines under the prompt's, at the card's width and
/// its type (`type`: the prompt's and the reply's line heights, which a text size or density changes).
type Fit = { width: number; type: string; lineHeight: number; lines: number };
/// The card's type as `Fit.type` keeps it: one style read each, no layout of their own.
function typeOf(prompt: HTMLElement, reply: HTMLElement): { type: string; prompt: number; reply: number } | undefined {
  const view = prompt.ownerDocument.defaultView;
  if (!view) return undefined;
  const promptLine = Number.parseFloat(view.getComputedStyle(prompt).lineHeight) || 20;
  const replyLine = Number.parseFloat(view.getComputedStyle(reply).lineHeight) || promptLine;
  return { type: `${promptLine}/${replyLine}`, prompt: promptLine, reply: replyLine };
}
/// What a fit is remembered by: the reply's blocks (a turn keeps its own) and the text beside them.
type FitKey = { reply: readonly ReplyBlock[]; text: string };
/// Every card's measured budgets, by what it showed (PreviewCard `fit`). A sweep back over rows it
/// crossed writes their budgets and reads once, instead of measuring the prompt and the reply again.
/// Weak by the reply's blocks, so a turn that goes takes its entries with it.
const fits = new WeakMap<readonly ReplyBlock[], Map<string, Fit>>();
const fitOf = ({ reply, text }: FitKey) => fits.get(reply)?.get(text);
function rememberFit({ reply, text }: FitKey, fit: Fit): void {
  let byText = fits.get(reply);
  if (!byText) fits.set(reply, (byText = new Map()));
  byText.set(text, fit);
}

/// Sets the reply's line budget, writing only what changed: an unchanged inline style restyles nothing.
function budget(reply: HTMLElement, lines: number, lineHeight: number): void {
  const set = (name: string, value: string) => {
    if (reply.style.getPropertyValue(name) !== value) reply.style.setProperty(name, value);
  };
  set("--acpmux-minimap-reply-lines", String(lines));
  set("--acpmux-minimap-reply-line-height", `${lineHeight}px`);
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
  /// Writes the card's transform: `from` (the rail's origin, `origin`) plus `x`, and its `height`
  /// centered on `center` inside the viewport. Writes only.
  const move = useCallback((node: HTMLElement, from: { x: number; y: number }, height: number) => {
    const { x: inset, center: middle, viewportHeight: room, layer: into, side: edge } = at.current;
    const top = cardOffset(middle, height, room);
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
  /// Puts the card beside its row. It writes the transform itself, before paint, with no state: a
  /// card that opens, follows the pointer to another row or grows renders once, and lays out once for
  /// the reads here (#28540: an origin and a height held in state took three commits and six forced
  /// layouts to open a card). Every read comes before the one write.
  const place = useCallback(() => {
    const node = self.current;
    if (!node) return;
    const from = origin(node);
    move(node, from, node.offsetHeight);
  }, [origin, move]);
  // The text budget is six lines: the old two-line prompt plus four-line reply. Measure the
  // prompt's actual wrapped lines when the card opens (and when its width changes), then give the
  // reply the remaining whole lines. Metadata and failure details keep their old natural rows.
  /// Sets the reply's line budget for this card's kind, in place (no state: it changes no React
  /// output), then places the card by its height after that change. Every card kind takes this one
  /// path, at open and on every resize, so a card reused for another kind (a prompt's card, then a
  /// reply's) is measured after its clamp changed, never before (#28540 review). Returns the card's
  /// size as that last read found it.
  ///
  /// Each row a sweep crosses fits the card (Leo, 2026-11-04: "hovering across the session rail gets
  /// a bit laggy ... it needs to get faster"). Every read after a write lays the page out again, and
  /// this read and wrote by turns: with the commit's place before it, four forced layouts per row
  /// (test/thread-rail-hover-reads.test.tsx). Now its reads come first and its writes after, in three
  /// passes on a row it has not measured (the prompt's lines with the card's place, the reply's
  /// natural height with its clamp lifted, the card's height under its budget), and a row it has
  /// measured at this width (`known`) writes its remembered budget and reads once.
  const fit = useCallback(
    (node: HTMLElement, promptCard: boolean, known: FitKey, reuse: boolean): { width: number; height: number } => {
      const replyNode = node.querySelector<HTMLElement>(".acpmux-minimap__reply");
      const promptNode = node.querySelector<HTMLElement>(".acpmux-minimap__prompt");
      const settle = () => {
        const from = origin(node);
        const size = { width: node.offsetWidth, height: node.offsetHeight };
        move(node, from, size.height);
        return size;
      };
      if (!promptCard || !replyNode || !promptNode) {
        // A reply's card takes the reply's own clamp (data-only): no prompt card's budget.
        replyNode?.style.removeProperty("--acpmux-minimap-reply-lines");
        replyNode?.style.removeProperty("--acpmux-minimap-reply-line-height");
        // The budget sets the card's height, and with it where the card centers.
        return settle();
      }
      const remembered = reuse ? fitOf(known) : undefined;
      if (remembered) {
        budget(replyNode, remembered.lines, remembered.lineHeight);
        // One read pass after the write: the card's place and size, and its type, which the budget
        // does not change. A text size or density changed since the fit (with the card closed, so
        // its observer never saw it) measures again below, as does a card drawn wider or narrower.
        const from = origin(node);
        const size = { width: node.offsetWidth, height: node.offsetHeight };
        if (size.width === remembered.width && typeOf(promptNode, replyNode)?.type === remembered.type) {
          move(node, from, size.height);
          return size;
        }
      }
      const type = typeOf(promptNode, replyNode);
      if (!type) return settle();
      const lineHeight = type.prompt;
      const replyLineHeight = type.reply;
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
        Math.min(4, Math.ceil(replyNode.getBoundingClientRect().height / replyLineHeight)),
      );
      if (clamp === null) replyNode.removeAttribute("style");
      else replyNode.setAttribute("style", clamp);
      // Match the old two-line prompt + four-line reply text budget for this same content. A
      // longer prompt spends only the reply lines it needs, so the card never grows because of it.
      const oldTextLines = Math.min(2, promptLines) + naturalReplyLines;
      const lines = Math.max(1, Math.min(4, oldTextLines - promptLines));
      // The reply clamp uses the reply's own settled 20px row. Measuring and budgeting with the
      // same value prevents a partial next row while prompt body copy stays on the denser 18px token.
      budget(replyNode, lines, replyLineHeight);
      // The budget sets the card's height, and with it where the card centers.
      const size = settle();
      rememberFit(known, {
        width: size.width,
        type: type.type,
        lineHeight: replyLineHeight,
        lines,
      });
      return size;
    },
    [origin, move],
  );
  /// The card's kind as of the last render, for the observer below, which outlives a content change.
  const promptCard = useRef(prompt !== undefined);
  promptCard.current = prompt !== undefined;
  /// What the card shows, as its fit remembers it (`fitOf`): the reply's blocks, which a turn keeps,
  /// and what else wraps the prompt and the reply.
  const content: FitKey = {
    reply,
    text: `${pending ? "\u0001" : ""}${prompt ?? ""}\u0000${bookmark ? 1 : 0}`,
  };
  const known = useRef(content);
  known.current = content;
  /// The card's size as of its last fit: a resize notification of that size (the observer's first,
  /// or the one the fit's own budget change causes) fits nothing again.
  const fitted = useRef({ width: -1, height: -1 });
  /// `reuse`: a new row may take its remembered budget. A resize the observer saw (a font or an image
  /// loading, a wrap) measures again, and that measure is what the row remembers from then on.
  const refit = useCallback(
    (node: HTMLElement, reuse: boolean) => {
      // Laid out by the fit's own last read, and the size it returns.
      fitted.current = fit(node, promptCard.current, known.current, reuse);
    },
    [fit],
  );
  /// The content the card was last fitted for: a commit that changes it fits (and so places) the
  /// card; any other only places it.
  const fittedFor = useRef<readonly unknown[]>([]);
  // After every commit on purpose: the rail can move under the card with any render. A new prompt,
  // reply or failure (the pointer reaching another row), or a change of kind, fits it once, and the
  // fit places it: one pass, not a place and then a fit that places it again.
  useLayoutEffect(() => {
    const node = self.current;
    if (!node) return;
    const now = [metadata?.failure, metadata?.failed, prompt, from, reply];
    if (
      now.length === fittedFor.current.length &&
      now.every((value, index) => Object.is(value, fittedFor.current[index]))
    )
      return place();
    fittedFor.current = now;
    refit(node, true);
  });
  // After the card is placed, so the blur's first measure finds it where it draws.
  useSeeThroughBlur(self, !!layer, underCard);
  // Content that grows or shrinks without a render (a font or an image loading, a wrap) fits again.
  // One observer for the card's life, not one per row the pointer crosses (each new one notifies on
  // observe, which fitted the card a second time per move). It stops with the card: disconnected in
  // the cleanup when the card goes.
  useLayoutEffect(() => {
    const node = self.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (node.offsetWidth === fitted.current.width && node.offsetHeight === fitted.current.height) return;
      refit(node, false);
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
      data-incoming={from !== undefined || undefined}
      data-pending={pending || undefined}
      data-arrived={arrived || undefined}
      aria-busy={pending || undefined}
      // Its transform is `place`'s, written before paint; on the right with no layer it is pinned to
      // the right edge (left: auto; right: 0) and `place` counts `x` in from there.
      style={cardStyle}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      onWheel={layer ? (event) => forwardWheel(scroller!, event.nativeEvent) : undefined}
      onFocus={onFocus}
      onBlur={onBlur}
    >
      {prompt !== undefined && from !== undefined && (
        <div className="acpmux-minimap__from">{t("minimap.from", { name: from })}</div>
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
