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
  /// The last launch's copy of the chat is on screen (chatSnapshot/live.ts `showsChatSnapshot`):
  /// what the person sees is the chat already, so the live page takes over only with the chat itself.
  keepsLastFrame?: boolean;
  /// The chat's own rows are in, from its attach or a kept tail (the client's `chatRead`), with the
  /// chat it names: not a retry still connecting, not the draw hold running out.
  chatRead?: boolean;
  /// The client said the chat's open failed (`connection: "failed"`): that is what the chat is now.
  openRefused?: boolean;
  /// acpmux answered that it lists no such chat, and why (deleted, offline, paused; not a machine
  /// still connecting): the pane's unavailable state, with its Reconnect or Resume, is the chat now.
  chatUnavailable?: boolean;
};

/// Whether the page shows what it is: the chat it opened, the failure that keeps it from opening,
/// or a New Tab page. A failed handshake is what the page is only once it is said: a quiet one,
/// while acpmux comes back after an update (hostRetry.ts `hostErrorShows`), draws nothing but an
/// empty transcript, and counting it took the chat's copy and the host's picture off for that empty
/// pane until acpmux answered and the rows came back (Leo, 2026-11-09: "the chat loading kinda
/// flickered in and out and layout shifted"). The copy stays until the chat is read or the failure
/// is said.
///
/// Over the last launch's copy the page never steps back (Leo, 2026-11-09: "It shows me a glimpse of
/// the past thing, and then it regresses into the skeletons and placeholders, and then it gets back
/// to the true thing"): a quiet retry (`connecting:`, acpmux still restoring after an update) or the
/// draw hold running out (App.tsx CHAT_DRAW_HOLD_MS) drew an empty transcript, a pill reading
/// "Model" and an empty ring in the copy's place. With a copy up, only the chat's own rows, a said
/// failure, a refused open or acpmux's answer that the chat is unavailable replace it; past live.ts SNAPSHOT_HOLD_MS the copy goes anyway.
/// restore-monotonic-trace.test.tsx records every surface through a relaunch and fails on a step down.
export function pageShowsWhatItIs(state: FirstPaintState): boolean {
  if (state.hostErrorSaid || state.newTab) return true;
  if (state.keepsLastFrame)
    return (
      state.handshaken && (state.chatRead === true || state.openRefused === true || state.chatUnavailable === true)
    );
  return state.handshaken && state.chatDrawn;
}
