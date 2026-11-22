// What the pane says to a screen reader on its own (a11y gaps 1 and 2, cmuxterm-hq
// docs/findings/2026-11-22-a11y-gap-list.md): an ask that starts waiting on the person, and a turn
// that ends. Nothing else is spoken here: the streamed text is the transcript's, read on demand.

/// One ask the pane shows: a permission card, a sub-chat's ask, a secret, a pinned question.
/// `key` stays the same while the same ask waits; `title` is its one-line name, or empty.
export type PaneAsk = { key: string; title: string };

export type PaneAnnouncerState = {
  /// The chat these values belong to: a switch to another chat is no turn ending.
  sessionId: string | undefined;
  asks: ReadonlySet<string>;
  working: boolean;
};

export type PaneAnnouncement = { kind: "ask"; title: string } | { kind: "finished" };

export function announcerState(
  sessionId: string | undefined,
  asks: readonly PaneAsk[],
  working: boolean,
): PaneAnnouncerState {
  return { sessionId, asks: new Set(asks.map((ask) => ask.key)), working };
}

/// What changed between two renders that the person should hear, or undefined. A new ask wins over
/// a turn's end in the same render: the ask is what waits on them. The newest new ask is the one named.
export function paneAnnouncement(
  before: PaneAnnouncerState,
  sessionId: string | undefined,
  asks: readonly PaneAsk[],
  working: boolean,
): PaneAnnouncement | undefined {
  for (let index = asks.length - 1; index >= 0; index--) {
    const ask = asks[index]!;
    if (!before.asks.has(ask.key)) return { kind: "ask", title: ask.title.trim() };
  }
  if (before.sessionId !== sessionId) return undefined;
  if (before.working && !working) return { kind: "finished" };
  return undefined;
}
