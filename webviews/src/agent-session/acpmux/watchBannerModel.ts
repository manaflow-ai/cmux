/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  // l10n-allow: product names (Codex, Claude Code), never translated.
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}

/// Whether a watched chat (acpmux's session summary) is a Claude desktop session acpmux lists and delivers messages into
/// (acpmux `hub/desktop_bridge.rs`, `hub/bridge.rs`): a reply goes to the app, so it takes nothing
/// over, whichever entrypoint the bridge lists. The daemon's bridge sets the tag, never a sender.
export function bridgedWatch(
  summary: { watching?: string | null; tags?: Record<string, string> } | undefined,
): boolean {
  return summary?.watching === "claude" && summary.tags?.bridge === "claude";
}
