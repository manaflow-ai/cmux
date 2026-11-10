// The transcript's overlays and the zone each one owns (design/transcript-overlays.md). Leo,
// 2026-11-10: the top left "is just where your eye naturally settles ... where you expect certain
// things to come in, that dynamism versus like what parts of the UI you expect to not change."
//
// Two kinds of zone:
// - dynamic zones, where arrival and status come and go: what is new arrives at the top start of
//   the transcript's column (the unread banner); where to go next waits at the bottom center, over
//   the composer's center line (Jump up stacked on Jump to latest, or the Needs you pill);
// - stable zones, which never move for something arriving: the header's top center (the pinned
//   "Subagent of" pill), and the end edge (Session Info), which pushes the column, never covers a
//   dynamic zone.
//
// Every overlay over the transcript is listed here once, with its zone, so nothing new lands
// somewhere a reader does not expect it: overlayLayout.test.ts fails on an overlay with no zone,
// on two that share a slot without being one stack, and on CSS that places one outside its zone.

export type OverlayZone = "top-start" | "top-center" | "bottom-center" | "end";
export type ZoneKind = "dynamic" | "stable";

export const ZONE_KIND: Record<OverlayZone, ZoneKind> = {
  "top-start": "dynamic",
  "bottom-center": "dynamic",
  "top-center": "stable",
  end: "stable",
};

export type TranscriptOverlay = {
  zone: OverlayZone;
  /// The CSS class that draws it (conversation.css, unread.css, sessionInfo.css, needsYou.css).
  className: string;
  /// Overlays that share a zone are one stack, in order from the zone's edge inward.
  stack?: number;
};

export const TRANSCRIPT_OVERLAYS = {
  unreadBanner: { zone: "top-start", className: "acpmux-since-jump" },
  subagentOf: { zone: "top-center", className: "acpmux-pinned-top" },
  jumpToLatest: { zone: "bottom-center", className: "acpmux-jump-latest", stack: 0 },
  jumpUp: { zone: "bottom-center", className: "acpmux-jump-up", stack: 1 },
  sessionInfo: { zone: "end", className: "acpmux-session-info" },
} as const satisfies Record<string, TranscriptOverlay>;

export type TranscriptOverlayName = keyof typeof TRANSCRIPT_OVERLAYS;

/// Where the top zones start, px from the stage's top: the transcript's clear line (under the
/// header and the tab row, VirtualTranscript.tsx `clearTop`), and under the pinned "Subagent of"
/// pill when a subagent's view shows one, so the top-start banner never covers it.
export function topZoneOffset({
  clearTop,
  floor = 0,
  pinnedBottom,
}: {
  clearTop: number;
  /// The bottom of the pane's tab row: nothing over the top draws above it (#40065).
  floor?: number;
  /// The pinned pill's bottom edge, when one is pinned.
  pinnedBottom?: number;
}): number {
  return Math.max(floor, pinnedBottom ?? clearTop, clearTop);
}
