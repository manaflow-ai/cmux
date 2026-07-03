export const comparePages = [
  {
    slug: "best-terminal-for-ai-coding-agents",
    key: "bestTerminalForAgents",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-alacritty",
    key: "cmuxVsAlacritty",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-conductor",
    key: "cmuxVsConductor",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-cursor",
    key: "cmuxVsCursor",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-devin",
    key: "cmuxVsDevin",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-ghostty",
    key: "cmuxVsGhostty",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-herdr",
    key: "cmuxVsHerdr",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-iterm2",
    key: "cmuxVsIterm2",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-kitty",
    key: "cmuxVsKitty",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-opencode",
    key: "cmuxVsOpencode",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-superset",
    key: "cmuxVsSuperset",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-tmux",
    key: "cmuxVsTmux",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-vscode",
    key: "cmuxVsVscode",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-warp",
    key: "cmuxVsWarp",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-wezterm",
    key: "cmuxVsWezterm",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-windsurf",
    key: "cmuxVsWindsurf",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-zed",
    key: "cmuxVsZed",
    lastModified: "2026-07-03",
  },
  {
    slug: "multiple-claude-code-agents-parallel",
    key: "multipleClaudeAgents",
    lastModified: "2026-07-03",
  },
] as const;

export type ComparePage = (typeof comparePages)[number];
export type ComparePageKey = ComparePage["key"];

export function comparePath(slug: string) {
  return `/compare/${slug}`;
}

export function comparePageForSlug(slug: string): ComparePage | undefined {
  return comparePages.find((page) => page.slug === slug);
}
