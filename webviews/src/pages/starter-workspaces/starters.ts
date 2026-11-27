// l10n-allow-file: first cut, English only until the starters settle.
// The built-in demo starters; the host (HomeHostView+SetupCard.swift) makes each one's folder and workspace.
import type { Starter } from "./StarterWorkspaces";

export const STARTER_DEMOS: Starter[] = [
  { id: "bug", kind: "demo", title: "Fix a planted bug", detail: "A small TypeScript repo with one failing test. Watch an agent find and fix it.", panes: ["Terminal", "Claude Code"], minutes: 3 },
  { id: "race", kind: "demo", title: "Agents side by side", detail: "Claude Code and Codex on the same task in two splits. Compare the diffs.", panes: ["Claude Code", "Codex", "Diff"], minutes: 5 },
  { id: "review", kind: "demo", title: "Review a pull request", detail: "A sample PR with its diff, a browser preview and a chat about it.", panes: ["Diff", "Browser", "Chat"], minutes: 4 },
  { id: "web", kind: "demo", title: "Build a page live", detail: "A dev server in a terminal, the page in a browser split, an agent editing it.", panes: ["Terminal", "Browser", "Claude Code"], minutes: 5 },
];
