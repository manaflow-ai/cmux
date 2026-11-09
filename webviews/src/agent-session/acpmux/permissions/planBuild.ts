/// Where a plan approval's plan is built (`_acpmux/plan/build`): here (Approve plan), in a new
/// worktree as a sub-session, or on two harnesses in two worktrees to compare.
export type PlanBuildTarget = "here" | "worktree" | "compare";

/// A target the card's build menu offers beside Approve plan, which is `here`.
export type PlanBuildElsewhere = Exclude<PlanBuildTarget, "here">;

export type PlanBuildWorktree = { root: string; branch: string; base?: string | null };

/// `_acpmux/plan/build`'s reply: the chats it started, none for `here`.
export type PlanBuildReply = {
  target: PlanBuildTarget;
  buildId: string | null;
  builds: { sessionId: string; name: string; harness: string; worktree: PlanBuildWorktree | null }[];
};

/// One run of a plan build as `_acpmux/plan/compare` and `_acpmux/plan/keep` report it.
export type PlanCompareBuild = {
  sessionId: string;
  name: string;
  harness: string;
  status: string;
  archived: boolean;
  branch?: string | null;
  base?: string | null;
  root?: string | null;
  added: number;
  removed: number;
  files: { path: string; added: number; removed: number }[];
  error?: string;
};

export type PlanCompareReply = {
  buildId: string;
  target: PlanBuildTarget;
  keptSessionId: string | null;
  builds: PlanCompareBuild[];
};

const HARNESS_NAMES: Record<string, string> = {
  claude: "Claude",
  codex: "Codex",
  gemini: "Gemini",
  grok: "Grok",
  cursor: "Cursor",
  opencode: "OpenCode",
};

/// A harness id as its product name ("claude-opus" is Claude), else the id itself.
export function harnessName(harness: string): string {
  const family = harness.split(/[-/]/)[0] ?? harness;
  return HARNESS_NAMES[family] ?? harness;
}

/// The two harnesses a compare build runs when the card names none, as the daemon picks them:
/// the chat's own, then Codex beside Claude and Claude beside anything else.
export function compareHarnesses(harness: string | undefined): [string, string] {
  const own = harness ? (harness.split(/[-/]/)[0] ?? harness) : "claude";
  return [own, own === "claude" ? "codex" : "claude"];
}

/// A host action's `target` as a build target; anything else is refused before it is sent.
export function planBuildTarget(value: unknown): PlanBuildTarget {
  if (value === "here" || value === "worktree" || value === "compare") return value;
  // l10n-allow: refuses a malformed host action; never shown.
  throw new Error(`unknown plan build target ${String(value)}`);
}
