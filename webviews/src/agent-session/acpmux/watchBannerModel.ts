/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  // l10n-allow: product names (Codex, Claude Code), never translated.
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}

/// Whether a watched chat (acpmux's session summary) is a Claude or Codex desktop session acpmux lists and delivers
/// messages into (acpmux `hub/desktop_bridge.rs`, `hub/bridge.rs`): a reply goes to the app, so it takes nothing
/// over, whichever entrypoint the bridge lists. The daemon's bridge sets the tag, never a sender.
export function bridgedWatch(
  summary: { watching?: string | null; tags?: Record<string, string> } | undefined,
): boolean {
  const family = summary?.watching;
  return (family === "claude" || family === "codex") && summary?.tags?.bridge === family;
}

/// Whether a watched chat is one its own Toggle Terminal and Chat handed to a cmux terminal (acpmux
/// `hub/release_to_watch.rs` tags it `via: terminal`): the terminal and the chat are two live views of one
/// session, so a reply goes into the terminal's harness and the chat shows no View Only banner.
export function terminalWatch(
  summary: { watching?: string | null; tags?: Record<string, string> } | undefined,
): boolean {
  return bridgedWatch(summary) && summary?.tags?.via === "terminal";
}

/// A bridged reply acpmux refused as read-only: the app no longer runs the session (or the bridge
/// was turned off since the chat was listed), so the chat is taken over and the reply kept for the next send.
export function bridgeGone(error: unknown): boolean {
  return (error as { reason?: unknown } | null)?.reason === "watch.read_only";
}
