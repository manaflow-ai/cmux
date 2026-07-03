export const comparePages = [
  {
    slug: "best-terminal-for-ai-coding-agents",
    key: "bestTerminalForAgents",
    lastModified: "2026-07-03",
  },
  {
    slug: "multiple-claude-code-agents-parallel",
    key: "multipleClaudeAgents",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-superset",
    key: "cmuxVsSuperset",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-cursor",
    key: "cmuxVsCursor",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-warp",
    key: "cmuxVsWarp",
    lastModified: "2026-07-03",
  },
  {
    slug: "cmux-vs-ghostty",
    key: "cmuxVsGhostty",
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
