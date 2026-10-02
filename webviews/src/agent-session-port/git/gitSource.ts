// Git data for the Changes panel. Owner: the shared git service in the `cmux` binary
// (session host role, spec/acp-ui.md S8), reached through the planned `git.status` and
// `git.diff {scope}` ops that Leo's lane builds. Until they exist, `mockGitSource` answers
// with a fixed working-tree diff; "Last Turn" never needs git: it is the turn's own tool
// diffs from acpmux.
import type { ChangeScope, ChangeSet, ChangedFile, ChangesLoad } from "../changes/model";
import { parseGitDiff } from "../changes/fixtures/second-pass";
import type { PortTurn } from "../viewModel/acpmuxTurns";
import { diffStats } from "../conversation/derive";
import MOCK_PATCH from "../changes/fixtures/second-pass-patch";

export interface GitStatus {
  branch?: string;
  upstream?: string;
  /** Untracked files skipped by the scan (the tracked-only banner). */
  untrackedSkipped?: number;
}

export interface GitSource {
  status(cwd: string): Promise<GitStatus>;
  /** `git.diff {scope}`: a scope other than lastTurn. */
  diff(cwd: string, scope: Exclude<ChangeScope, "lastTurn">): Promise<ChangeSet>;
}

/** Stand-in for `git.status`/`git.diff` until the daemon serves them. */
export const mockGitSource: GitSource = {
  async status() {
    return { branch: "feat/acp-port", upstream: "origin/main", untrackedSkipped: 0 };
  },
  async diff(_cwd, scope) {
    const files = parseGitDiff(MOCK_PATCH);
    if (scope === "branch") return { scope, head: "feat/acp-port", base: "origin/main", files };
    if (scope === "staged" || scope === "committed") return { scope, files: [] };
    return { scope, files };
  },
};

/** The Last Turn scope: every file the turn's tool calls changed, net per file. */
export function lastTurnChanges(turn: PortTurn | undefined): ChangesLoad {
  const byPath = new Map<string, ChangedFile>();
  for (const item of turn?.items ?? []) {
    if (item.type !== "fileChange") continue;
    for (const change of item.changes) {
      const stats = diffStats(change);
      const previous = byPath.get(change.path);
      const header = `diff --git a/${change.path} b/${change.path}\n--- ${change.kind.type === "add" ? "/dev/null" : `a/${change.path}`}\n+++ b/${change.path}\n`;
      byPath.set(change.path, {
        path: change.path,
        status: change.kind.type === "add" ? "added" : change.kind.type === "delete" ? "deleted" : "modified",
        additions: (previous?.additions ?? 0) + stats.additions,
        deletions: (previous?.deletions ?? 0) + stats.deletions,
        patch: `${previous?.patch ?? header}${change.diff.endsWith("\n") ? change.diff : `${change.diff}\n`}`,
      });
    }
  }
  const files = [...byPath.values()];
  return files.length ? { status: "loaded", changeSet: { scope: "lastTurn", files } } : { status: "empty" };
}
