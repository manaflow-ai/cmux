// The project languages a badge can draw (FileTypeIcon.tsx LanguageIcon), apart from the icon set
// itself so a badge can tell an icon from letters before the set loads.

/// The languages and frameworks the host names from a project's marker files
/// (AgentPaneProjectIcon.swift `markers`) that the set has an icon for.
export const LANGUAGE_ICONS: ReadonlySet<string> = new Set([
  "astro",
  "docker",
  "go",
  "javascript",
  "nextjs",
  "python",
  "ruby",
  "rust",
  "svelte",
  "swift",
  "typescript",
  "vite",
  "zig",
]);
