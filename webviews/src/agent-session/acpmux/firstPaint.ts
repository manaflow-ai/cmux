// When the chat page has drawn what it is, so the host may show it: the page reports `pane.painted`
// then, and the chat's copy from the last launch (chatSnapshot/live.ts) and the host's saved picture
// of the pane give way to the live page (App.tsx).

export type FirstPaintState = {
  /// acpmux answered the page's handshake.
  handshaken: boolean;
  /// The chat the handshake named is read (its rows are in), or its open failed or ran out of time.
  chatDrawn: boolean;
  /// The page's last handshake failed (`hostError`), said or not.
  hostError: boolean;
  /// That failure is said on the page (hostRetry.ts `hostErrorShows`, or a Restart acpmux runs).
  hostErrorSaid: boolean;
  /// The page is a New Tab page, which is what it is from its first render.
  newTab: boolean;
};

/// Whether the page shows what it is: the chat it opened, the failure that keeps it from opening,
/// or a New Tab page. A failed handshake is what the page is only once it is said: a quiet one,
/// while acpmux comes back after an update (hostRetry.ts `hostErrorShows`), draws nothing but an
/// empty transcript, and counting it took the chat's copy and the host's picture off for that empty
/// pane until acpmux answered and the rows came back (Leo, 2026-11-09: "the chat loading kinda
/// flickered in and out and layout shifted"). The copy stays until the chat is read or the failure
/// is said.
export function pageShowsWhatItIs(state: FirstPaintState): boolean {
  return (state.handshaken && state.chatDrawn) || state.hostErrorSaid || state.newTab;
}
