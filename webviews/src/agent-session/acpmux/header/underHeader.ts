/// The lines that sit in flow straight under the chat's header, above the transcript: a Create Checkpoint
/// review, a live chat's choice, why a chat drawn from its last-read rows is not here, a peer copy that is offline, a watched chat's banner (or its take-over
/// choice), a handoff error. App.tsx renders each one only when its flag here is set, and a one-tab pane's
/// transcript runs up under the tab row (header/tabRow.ts `soloTab`) only when none is set, so a line added
/// under the header joins this record and can never be overlapped by the transcript (the review at a
/// one-tab pane's top once took the clicks on its Create and Refresh buttons that way).
export type UnderHeaderLines = {
  checkpointReview: boolean;
  liveChat: boolean;
  peerCopy: boolean;
  /// The tab's chat is not listed yet, drawn from its last-read rows (ChatUnavailableState `line`).
  unavailable: boolean;
  watching: boolean;
  handoffError: boolean;
  /// A result-first subagent header is also an in-flow line under the header.
  resultHead: boolean;
};

/// Whether any line sits under the header.
export const anyUnderHeader = (lines: UnderHeaderLines): boolean => Object.values(lines).some(Boolean);

/// Whether the transcript runs up under a one-tab pane's row: only straight below the header.
export const runsUnderTabRow = (soloTab: boolean, lines: UnderHeaderLines): boolean =>
  soloTab && !anyUnderHeader(lines);
