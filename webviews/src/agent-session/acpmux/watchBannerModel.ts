/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  // l10n-allow: product names (Codex, Claude Code), never translated.
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}
