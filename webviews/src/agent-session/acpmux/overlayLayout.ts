// The transcript's overlays and the zone each one owns (design/transcript-overlays.md). Leo,
// 2026-11-10: the top left "is just where your eye naturally settles ... where you expect certain
// things to come in, that dynamism versus like what parts of the UI you expect to not change."
//
// Two kinds of zone:
// - dynamic zones, where arrival and status come and go: where to go next waits at the bottom
//   center, over the composer's center line: the one jump control (up to unread turns, or down to
//   the latest message, or the Needs you pill; jumpControl.ts), never two;
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
  subagentOf: { zone: "top-center", className: "acpmux-pinned-top" },
  jumpControl: { zone: "bottom-center", className: "acpmux-jump-latest" },
  sessionInfo: { zone: "end", className: "acpmux-session-info" },
} as const satisfies Record<string, TranscriptOverlay>;

export type TranscriptOverlayName = keyof typeof TRANSCRIPT_OVERLAYS;
