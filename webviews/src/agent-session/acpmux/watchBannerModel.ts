/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  // l10n-allow: product names (Codex, Claude Code), never translated.
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}

/// Whether a watched chat (acpmux's session summary) is a Claude desktop session acpmux lists and delivers messages into
/// (acpmux `hub/desktop_bridge.rs`, `hub/bridge.rs`): a reply goes to the app, so it takes nothing
/// over. The tag comes from the session's own registry entry, never from a sender.
export function bridgedWatch(
  summary: { watching?: string | null; tags?: Record<string, string> } | undefined,
): boolean {
  return summary?.watching === "claude" && summary.tags?.origin === "claude-desktop";
}
