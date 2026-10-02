// Design tokens of the transcript. conversation.css reads every tunable metric from a
// `--cv-*` custom property with the Codex default; a `ConversationTokens` object passed to
// <Thread tokens={…}> overrides them for one thread. Captures of the same UI disagree by
// fractions of a pixel (window focus, scale snapping), so a capture family pins its
// measured values in a named variant (variants.ts) instead of a per-screen stylesheet.
import type { CSSProperties } from "react";

export type ConversationTokens = {
  /** Body text color, secondary text color, font size, line height and tracking. */
  text?: string;
  textMuted?: string;
  fontSize?: number;
  lineHeight?: number;
  tracking?: number;
  /** Horizontal sub-pixel shift of the whole thread (the main column starts on x.5). */
  shiftX?: number;

  /* User bubble */
  bubbleBg?: string;
  bubbleLineHeight?: number;
  bubblePadding?: string;
  /** Bubble width; default shrink-to-fit up to 70% of the column. */
  bubbleWidth?: string;
  /** Height and offsets of the copy/edit row under the bubble (0 removes it). */
  userActionsHeight?: number;
  userActionsGap?: number;
  userActionsRight?: number;
  /** Gap between a bubble (with its action row) and the following assistant turn. */
  userAfter?: number;
  /** Gap between an assistant turn (with its action row) and the next bubble. */
  turnAfter?: number;

  /* Timestamp */
  timestampTop?: number;
  timestampAfter?: number;

  /* Worked-for row */
  workedTop?: number;
  workedHeight?: number;
  workedPadTop?: number;
  workedAfter?: number;
  workedGap?: number;
  workedChevronGap?: number;
  workedChevronTop?: number;
  workedRule?: string;
  /** Tabular digits ("1m 16s"); captures of other turns use proportional digits. */
  workedNumeric?: "tabular-nums" | "normal";

  /* Markdown */
  paraAfter?: number;
  /** Gap above a list that follows a paragraph, and below the list. */
  listBefore?: number;
  listAfter?: number;
  listIndent?: number;
  bulletLeft?: number;
  bulletTop?: number;
  bulletSize?: number;
  /** Space below the last block of a Markdown run. */
  mdAfter?: number;
  /** Extra left inset of Markdown text. */
  mdInset?: number;
  mdLineHeight?: number;
  codeFont?: string;
  codeSize?: number;
  codeRadius?: number;
  codePadding?: string;
  codeLineHeight?: string;
  codeTracking?: number;
  codeBg?: string;
  link?: string;
  linkIconMargin?: string;
  linkIconAlign?: number;
  ghIconAlign?: number;
  ghIconMargin?: string;
  /** Citation links ("Paper"). */
  citation?: string;
  citationIconAlign?: number;
  strongTracking?: number;

  /* Tables */
  tableSize?: number;
  tableLineHeight?: number;
  tableTracking?: number;
  tableBefore?: number;
  thPadTop?: number;
  thPadBottom?: number;
  tdPadY?: number;

  /* Tool rows */
  toolHeight?: number;
  toolGap?: number;
  toolBefore?: number;
  toolAfter?: number;
  toolStrong?: string;
  toolDetail?: string;
  toolChevronGap?: number;
  /** `nowrap` truncates long rows with an ellipsis (shell command rows). */
  toolWhiteSpace?: string;

  /* Edited files card */
  editedBefore?: number;
  editedAfter?: number;
  editedIconHeight?: number;
  editedIconSize?: number;
  editedIconColor?: string;
  editedTitleWeight?: string;
  editedViewRing?: number;

  /* Turn actions */
  turnActionsLeft?: number;
  turnActionsTop?: number;

  /* Scroll-to-bottom button */
  scrollBg?: string;
  scrollRing?: string;
};

const kebab = (s: string) => s.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);

/** Turn a token object (numbers are px) into `--cv-*` custom properties for an inline style. */
export function tokenStyle(tokens: ConversationTokens | undefined): CSSProperties {
  const out: Record<string, string> = {};
  if (!tokens) return out;
  for (const [k, v] of Object.entries(tokens)) {
    if (v === undefined) continue;
    out[`--cv-${kebab(k)}`] = typeof v === "number" ? `${v}px` : v;
  }
  return out as CSSProperties;
}
