// l10n-allow-file: gallery fixtures (sample pull requests), not shipped UI.
import { nativeEntry } from "../gallery/format";

// The native sidebar's pull request hover card (`SidebarPullRequestCardView`,
// `sidebar.pullRequestCard`): each variant's fixture is the `[SidebarPullRequestItem]` the row's
// badge hands the card, newest first, as `SidebarPullRequestCardTests` decodes it.
const pr = (
  number: number,
  title: string,
  state: string,
  additions: number,
  deletions: number,
  repository = "manaflow-ai/cmux",
) => ({
  url: `https://github.com/${repository}/pull/${number}`,
  repository,
  number,
  title,
  state,
  additions,
  deletions,
  createdAt: `2026-10-${String(10 + (number % 18)).padStart(2, "0")}T09:00:00Z`,
});

export default nativeEntry({
  id: "sidebar.pull-request-card",
  title: "Pull request hover card",
  area: "Native",
  covers: ["swift:SidebarPullRequestCardView", "swift:SidebarPullRequestCardRow"],
  height: 360,
  variants: {
    conflict: {
      note: "One open pull request whose branch conflicts with its base.",
      fixture: { items: [pr(21823, "acpmux: record the PRs each session opens", "conflict", 412, 37)] },
    },
    "checks-failed": {
      note: "Checks failed on the newest; the badge turns red.",
      fixture: {
        items: [
          pr(21851, "Sidebar pull request hover card", "failing", 688, 41),
          pr(21823, "acpmux: record the PRs each session opens", "passing", 412, 37),
        ],
      },
    },
    mixed: {
      note: "Every state, more than eight lines: the card scrolls.",
      fixture: {
        items: [
          pr(21860, "Session tree: keycaps follow Command-number order", "passing", 96, 12),
          pr(21858, "Hover card: crossfade between rows", "draft", 140, 20),
          pr(21851, "Sidebar pull request hover card", "failing", 688, 41),
          pr(21840, "acpmux: peers keep the session's pull requests", "conflict", 75, 9),
          pr(21823, "acpmux: record the PRs each session opens", "passing", 412, 37),
          pr(21814, "cmux NEXT sidebar: session tree", "merged", 1204, 88),
          pr(37, "Bump ghostty-next", "merged", 3, 3, "manaflow-ai/ghostty"),
          pr(21790, "Prototype: PR glyph in the row title", "closed", 30, 2),
          pr(21788, "acpmux vs Claude Code sessions", "merged", 210, 64),
          pr(21780, "Text probes wait on a FrameClient", "merged", 318, 120),
        ],
      },
    },
    "all-merged": {
      note: "Every pull request merged: the badge is purple.",
      fixture: {
        items: [
          pr(21814, "cmux NEXT sidebar: session tree", "merged", 1204, 88),
          pr(21788, "acpmux vs Claude Code sessions", "merged", 210, 64),
          pr(37, "Bump ghostty-next", "merged", 3, 3, "manaflow-ai/ghostty"),
        ],
      },
    },
    empty: {
      note: "No pull requests: the row shows no badge, so the card never opens.",
      fixture: { items: [] },
    },
  },
});
