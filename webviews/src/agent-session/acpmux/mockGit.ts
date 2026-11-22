// The mock daemon's git: what `git.diff` and `git.status` answer for the seeded sessions, in
// the shapes of cmux-tui's resource catalog. The worked session's branch holds the worked turn's edits, half staged, on top of
// one earlier commit; the dotfiles sessions sit outside a repository and fail to load.
import { diffHunks, diffLines, editPatch, type TurnFile } from "./diff";
import type { ChangedFile, ChangeScope } from "./changes/model";
import { mockSessions, WORKED_SESSION, workedSources } from "./mockFixture";

const manifestBefore = `export type Manifest = { name: string; files: string[] };

export function manifestFor(name: string, files: string[]): Manifest {
  return { name, files };
}
`;
const manifestAfter = `export type Manifest = { name: string; files: string[]; uploadedAt: string };

export function manifestFor(name: string, files: string[]): Manifest {
  return { name, files: [...files].sort(), uploadedAt: new Date().toISOString() };
}
`;

/// A file's change as git reports it: counts and the patch from its first `@@` on.
function changed(path: string, status: ChangedFile["status"], before: string | undefined, after: string): ChangedFile {
  const hunks = diffHunks(diffLines(before, after));
  const file: TurnFile = { path, displayPath: path, edits: [], additions: 0, deletions: 0, created: before == null };
  const patch = editPatch(file, { toolId: "git", hunks, numbered: true }).split("\n").slice(3).join("\n");
  const lines = hunks.flatMap((hunk) => hunk.lines);
  return {
    path,
    status,
    additions: lines.filter((line) => line.type === "add").length,
    deletions: lines.filter((line) => line.type === "del").length,
    patch,
  };
}

const { upload, retry, test } = workedSources;
const staged = [changed(retry.path, "added", undefined, retry.after)];
const unstaged = [
  changed(upload.path, "modified", upload.before, upload.after),
  changed(test.path, "modified", test.before, test.after),
];
const committed = [changed("Sources/Fleet/manifest.ts", "modified", manifestBefore, manifestAfter)];
const workedScopes: Record<Exclude<ChangeScope, "lastTurn">, ChangedFile[]> = {
  uncommitted: [...staged, ...unstaged],
  unstaged,
  staged,
  committed,
  branch: [...committed, ...staged, ...unstaged],
};

/// The sessions whose folder is not a git repository.
const outsideGit = new Set(mockSessions.filter((session) => session.cwd === "~/code/dotfiles").map((s) => s.sessionId));

const rootOf = (sessionId: string) =>
  mockSessions.find((session) => session.sessionId === sessionId)?.cwd ?? workedSources.root;

/// A GitDiffResult: patches only when asked for, as the session host does.
export function mockGitDiff(sessionId: string, scope: ChangeScope, includePatch: boolean) {
  if (outsideGit.has(sessionId)) throw new Error("Not a git repository");
  if (!Object.hasOwn(workedScopes, scope)) throw new Error(`Unknown scope ${scope}`);
  const files = sessionId === WORKED_SESSION ? workedScopes[scope as keyof typeof workedScopes] : [];
  // The compared commit: the merge base for branch, HEAD's first parent for committed.
  const base = scope === "branch" ? "origin/main" : scope === "committed" ? "4be1c2e~1" : undefined;
  return {
    scope,
    root: rootOf(sessionId),
    head: "4be1c2e",
    ...(base ? { base } : {}),
    files: files.map((file) => ({
      path: file.path,
      ...(file.previousPath ? { previous_path: file.previousPath } : {}),
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      ...(file.binary ? { binary: true } : {}),
      ...(includePatch && file.patch !== undefined ? { patch: file.patch } : {}),
      ...(includePatch && file.patchTruncated ? { patch_truncated: true } : {}),
    })),
    additions: files.reduce((sum, file) => sum + file.additions, 0),
    deletions: files.reduce((sum, file) => sum + file.deletions, 0),
    total_files: files.length,
    files_omitted: 0,
  };
}

/// A GitStatusResult.
export function mockGitStatus(sessionId: string) {
  if (outsideGit.has(sessionId)) throw new Error("Not a git repository");
  const session = mockSessions.find((entry) => entry.sessionId === sessionId);
  const branch = session?.branch ?? "main";
  return {
    root: rootOf(sessionId),
    detached: false,
    branch,
    upstream: "origin/main",
    base: "origin/main",
    ahead: 1,
    behind: 0,
  };
}
