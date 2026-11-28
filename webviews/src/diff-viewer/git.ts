// The viewer's Stage, Commit and Push (cx-ueuc8, dogfood run hq #1893): the chat header's ± opens
// this viewer, so it offers the changes view's git workflow, reused as is (useGitWrite, GitActions)
// over the host's `cmux.diff.git.*` ops. The host runs them in the tab's own repository and asks
// for a real click or key for each write. A host without the ops (the classic viewer, the dev
// server) gets no source, and the viewer shows no git controls.
import { useEffect, useState } from "react";
import { setPaneLanguage, translate } from "../agent-session/acpmux/i18n";
import type { ChangesSource } from "../agent-session/acpmux/changes/model";
import type { DiffSource } from "../diff/generated/protocol";
import type { PageClient } from "../pages/shared/pageClient";
import { diffGitStrings, diffViewerLanguage } from "../labels";
import { UNCOMMITTED_BASE_REF } from "../toolbar-model";
import { useSyncedRef } from "./useSyncedRef";

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

/// A file header's Stage (Unstaged, Uncommitted: the branch against HEAD, and Branch, as the
/// chat's ± opens it) or Unstage (Staged); undefined for a patch. Branch also shows commits, so
/// there Stage is offered only on files with work-tree changes (cx-4ukqc), read once per load
/// `generation`.
export function useDiffStageAction(
  source: ChangesSource | undefined,
  shown: DiffSource | null,
  generation: number,
  then: { staged: () => void; failed: (message: string) => void },
): { label: string; run: (path: string) => void; offers?: (path: string) => boolean } | undefined {
  const stage = source?.stage;
  const unstage = shown?.kind === "staged";
  const committedToo = shown?.kind === "branch" && shown.baseRef !== UNCOMMITTED_BASE_REF;
  const [workTree, setWorkTree] = useState<{ generation: number; paths: ReadonlySet<string> }>();
  useEffect(() => {
    if (!source || !committedToo) return;
    let current = true;
    source
      .diff("unstaged")
      .then((value) => {
        if (current) setWorkTree({ generation, paths: changedPaths(value) });
      })
      .catch(() => {});
    return () => {
      current = false;
    };
  }, [source, committedToo, generation]);
  const latest = useSyncedRef(then);
  if (!stage || !shown) return undefined;
  if (!unstage && shown.kind !== "unstaged" && shown.kind !== "branch") return undefined;
  const paths = workTree?.generation === generation ? workTree.paths : undefined;
  return {
    label: translate(unstage ? "changes.unstageFile" : "changes.stageFile"),
    run: (path) =>
      void stage([path], unstage).then(
        () => latest.current.staged(),
        () => latest.current.failed(translate("changes.stageFailed")),
      ),
    ...(committedToo ? { offers: (path: string) => paths?.has(path) === true } : {}),
  };
}

/// The paths a `git.diff` read names.
function changedPaths(value: unknown): ReadonlySet<string> {
  const files = (value as { files?: unknown } | null)?.files;
  if (!Array.isArray(files)) return new Set();
  return new Set(files.flatMap((file) => (typeof file?.path === "string" ? [file.path] : [])));
}

/// The reused components read the agent pane's string tables; the viewer's table carries their
/// `git.` strings (scripts/pages/gen-strings.mjs), loaded with the viewer's language.
function installGitStrings(): void {
  const language = diffViewerLanguage();
  globalThis.__cmuxPaneStrings = { ...globalThis.__cmuxPaneStrings, ...diffGitStrings(language) };
  setPaneLanguage(language);
}
