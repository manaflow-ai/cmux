// The viewer's Stage, Commit and Push (cx-ueuc8, dogfood run hq #1893): the chat header's ± opens
// this viewer, so it offers the changes view's git workflow, reused as is (useGitWrite, GitActions)
// over the host's `cmux.diff.git.*` ops. The host runs them in the tab's own repository and asks
// for a real click or key for each write. A host without the ops (the classic viewer, the dev
// server) gets no source, and the viewer shows no git controls.
import { setPaneLanguage, translate } from "../agent-session/acpmux/i18n";
import type { ChangesSource } from "../agent-session/acpmux/changes/model";
import type { DiffSource } from "../diff/generated/protocol";
import type { PageClient } from "../pages/shared/pageClient";
import { diffGitStrings, diffViewerLanguage } from "../labels";

export const DIFF_GIT_OPS = {
  status: "cmux.diff.git.status",
  diff: "cmux.diff.git.diff",
  commit: "cmux.diff.git.commit",
  push: "cmux.diff.git.push",
  stage: "cmux.diff.git.stage",
  unstage: "cmux.diff.git.unstage",
} as const;

/** The viewer's git, when the host lists every op it needs; undefined otherwise. */
export function diffGitSource(page: PageClient | null, ops: readonly string[] | undefined): ChangesSource | undefined {
  if (!page || !Object.values(DIFF_GIT_OPS).every((op) => ops?.includes(op))) return undefined;
  installGitStrings();
  const call = (op: string, params: Record<string, unknown> = {}) => page.call<unknown>(op, params);
  return {
    diff: (scope) => call(DIFF_GIT_OPS.diff, { scope }),
    status: () => call(DIFF_GIT_OPS.status),
    commit: (params) => call(DIFF_GIT_OPS.commit, params),
    push: (params) => call(DIFF_GIT_OPS.push, params),
    stage: (paths, unstage) => call(unstage ? DIFF_GIT_OPS.unstage : DIFF_GIT_OPS.stage, { paths }),
  };
}

/// A file header's Stage (Unstaged, and Uncommitted: the branch against HEAD) or Unstage (Staged);
/// undefined where the shown diff is not the work tree's or the index's (a patch, a branch).
export function diffStageAction(
  source: ChangesSource | undefined,
  shown: DiffSource | null,
  then: { staged: () => void; failed: (message: string) => void },
): { label: string; run: (path: string) => void } | undefined {
  const stage = source?.stage;
  if (!stage || !shown) return undefined;
  const unstage = shown.kind === "staged";
  if (!unstage && shown.kind !== "unstaged" && !(shown.kind === "branch" && shown.baseRef === "HEAD")) return undefined;
  return {
    label: translate(unstage ? "changes.unstageFile" : "changes.stageFile"),
    run: (path) => void stage([path], unstage).then(then.staged, () => then.failed(translate("changes.stageFailed"))),
  };
}

/// The reused components read the agent pane's string tables; the viewer's table carries their
/// `git.` strings (scripts/pages/gen-strings.mjs), loaded with the viewer's language.
function installGitStrings(): void {
  const language = diffViewerLanguage();
  globalThis.__cmuxPaneStrings = { ...globalThis.__cmuxPaneStrings, ...diffGitStrings(language) };
  setPaneLanguage(language);
}
