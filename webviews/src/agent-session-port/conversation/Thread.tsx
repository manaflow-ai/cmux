// Scrolling transcript area: a viewport with fades under the title bar and above the
// composer, a centered message column, and an optional docked composer.
import type { CSSProperties, ReactNode } from "react";
import { tokenStyle, type ConversationTokens } from "./tokens";
import { resolveScroll, type ScrollPosition } from "./useScrollPosition";
import { useCallback } from "react";
import { useScrollArea } from "../shell/scroll";
import "./conversation.css";

export type ThreadFade = {
  /** Fade length under the top edge, px. */
  top?: number;
  /** Fade length above `bottomAt`, px. */
  bottom?: number;
  /** Where content is fully faded out, measured from the bottom edge. Default: the composer's top edge. */
  bottomAt?: number;
};

export type ThreadProps = {
  /**
   * Space reserved on the right for a card floating over the transcript (the thread
   * summary), px. The scroller and its thumb still span the full width; the message column
   * and the composer center in what is left. Omitted: `--cv-reserve-right` from CSS (an
   * app stylesheet may derive it from the thread's container size), else 0.
   */
  right?: number;
  /** Width of the centered message column: px, or a CSS length such as `FLUID_COLUMN`. */
  columnWidth?: number | string;
  /** Space above the first message. */
  paddingTop?: number;
  /** Space below the last message (the composer overlaps the scroller's bottom). */
  paddingBottom?: number;
  /** Initial scroll position of the real scroll container. */
  scroll?: ScrollPosition;
  /** Composer (or the "open in another app" banner) docked to the column bottom. */
  composer?: ReactNode;
  /** Distance of the composer from the bottom edge. */
  composerBottom?: number;
  /** Height of the docked composer; content fades out above its top edge. */
  composerHeight?: number;
  /** Composer width when it differs from the column: px or a CSS length (`FLUID_COMPOSER`). */
  composerWidth?: number | string;
  /** Horizontal offset of the composer from the thread's center. */
  composerX?: number;
  fade?: ThreadFade;
  /** Extra layers positioned in the thread's coordinates (scroll-to-bottom button, …). */
  overlay?: ReactNode;
  /** Overlay scrollbar track insets from the thread's top and bottom edges, px. */
  thumbInset?: { top?: number; bottom?: number };
  /** Metric overrides for this thread (see tokens.ts and variants.ts). */
  tokens?: ConversationTokens;
  children?: ReactNode;
  style?: CSSProperties;
  className?: string;
};

/** Track insets of the transcript's overlay thumb (measured on fixture-project-created). */
const THUMB_INSET = { top: 4, bottom: 4 };

/**
 * Transcript area inside `<Main>`. Messages flow in a centered column (`columnWidth`,
 * default 736) of the region left of `right`. Position the thread elsewhere (e.g. in
 * window coordinates) with `style`.
 */
/**
 * A message column that fills the transcript (less the reserved right side) up to 736px,
 * keeping 26.5px gutters when the transcript is narrower (manual-*.png, live 1911px captures).
 */
export const FLUID_COLUMN = "min(736px, 100% - 53px)";
/** The docked composer beside a fluid column: 21.5px wider than a narrowed column (manual-*.png). */
export const FLUID_COMPOSER = "min(736px, 100% - var(--cv-reserve-right, 0px) - 53px + 21.5px)";

export function Thread({
  right,
  columnWidth = 736,
  paddingTop = 32,
  paddingBottom,
  scroll = 0,
  composer,
  composerBottom = 16,
  composerHeight = 98,
  composerWidth = columnWidth,
  composerX = 0,
  fade,
  overlay,
  thumbInset,
  tokens,
  children,
  style,
  className = "",
}: ThreadProps) {
  const bottomAt = fade?.bottomAt ?? (composer ? composerBottom + composerHeight : 0);
  // Anchors resolve against the laid-out content (`scroll` comes from state, so the
  // resolver is stable while the position is); "bottom" asks for the largest offset.
  const resolve = useCallback((el: HTMLElement) => resolveScroll(scroll, el), [scroll]);
  const {
    ref: scrollRef,
    handlers: scrollHandlers,
    thumb,
  } = useScrollArea(typeof scroll === "object" ? resolve : scroll === "bottom" ? 1e9 : scroll, {
    insetStart: thumbInset?.top ?? THUMB_INSET.top,
    insetEnd: thumbInset?.bottom ?? THUMB_INSET.bottom,
  });
  const viewportStyle = {
    "--cv-fade-top": fade?.top !== undefined ? `${fade.top}px` : undefined,
    "--cv-fade-bottom": `${fade?.bottom ?? (bottomAt ? 32 : 0)}px`,
    "--cv-fade-bottom-at": `${bottomAt}px`,
  } as CSSProperties;
  return (
    <div
      className={`cv-thread ${className}`}
      style={
        {
          ...(right !== undefined && { "--cv-reserve-right": `${right}px` }),
          ...tokenStyle(tokens),
          ...style,
        } as CSSProperties
      }
    >
      <div
        className="cv-thread__viewport"
        style={viewportStyle}
        ref={scrollRef}
        {...scrollHandlers}
      >
        <div
          className="cv-thread__column"
          style={{
            width: columnWidth,
            paddingTop,
            paddingBottom: paddingBottom ?? (composer ? composerBottom + composerHeight + 40 : 32),
          }}
        >
          {children}
        </div>
      </div>
      {thumb && (
        <span className="cv-thread__thumb" style={{ top: thumb.top, height: thumb.height }} />
      )}
      {overlay}
      {composer && (
        <div
          className="cv-thread__composer"
          style={{
            bottom: composerBottom,
            width: composerWidth,
            marginLeft: `calc(var(--cv-shift-x, -0.5px) + ${composerX}px)`,
          }}
        >
          {composer}
        </div>
      )}
    </div>
  );
}
