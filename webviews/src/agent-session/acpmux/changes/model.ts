// What the changes view shows beyond one turn: a git scope of the session's repository, after
// the Codex Changes pane in manaflow-ai/codex-atlas-clone (src/changes/model.ts). The session
// host answers `git.scope.diff {scope}` with a ChangeSet and `git.status` with a GitStatus
// (cmux-next-spec spec/acp-ui.md); the mock daemon answers both from its fixture.
import type { DiffHunk, DiffLine, TurnFile } from "../diff";

export type ChangeScope = "lastTurn" | "uncommitted" | "unstaged" | "staged" | "committed" | "branch";

export type ChangedFile = {
  /// Relative to the repository's top level.
  path: string;
  previousPath?: string;
  status: "added" | "modified" | "deleted" | "renamed" | "untracked";
  additions: number;
  deletions: number;
  /// The file's unified diff, from its `@@` hunks on; absent for a binary file.
  patch?: string;
  binary?: boolean;
};

export type ChangeSet = {
  scope: ChangeScope;
  /// The repository's top level, so a file's path can be copied or opened.
  root?: string;
  head?: string;
  base?: string;
  files: ChangedFile[];
  additions?: number;
  deletions?: number;
  /// Untracked files left out to keep the view responsive.
  untrackedSkipped?: number;
  totalFiles?: number;
  filesOmitted?: number;
};

export type GitStatus = {
  branch?: string;
  upstream?: string;
  base?: string;
  ahead: number;
  behind: number;
  detached?: boolean;
};

export type ChangesLoad =
  | { state: "loading" }
  | { state: "error"; message?: string }
  | { state: "loaded"; changeSet: ChangeSet };

/// Where the view reads a scope from: the session host, or the mock daemon in mock mode.
export type ChangesSource = { scopeDiff: (scope: ChangeScope) => Promise<unknown> };

/// The scope menu, top to bottom; `null` is a separator.
export const SCOPE_ORDER: (ChangeScope | null)[] = [
  "lastTurn",
  null,
  "uncommitted",
  "unstaged",
  "staged",
  null,
  "committed",
  "branch",
];

export const SCOPE_LABEL: Record<ChangeScope, string> = {
  lastTurn: "Last turn",
  uncommitted: "Uncommitted",
  unstaged: "Unstaged",
  staged: "Staged",
  committed: "Committed",
  branch: "Branch",
};

const STATUSES = new Set<ChangedFile["status"]>(["added", "modified", "deleted", "renamed", "untracked"]);
const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0);
const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/// A ChangeSet from whatever the host sent, or undefined when it isn't one.
export function readChangeSet(value: unknown, scope: ChangeScope): ChangeSet | undefined {
  if (!value || typeof value !== "object" || !Array.isArray((value as ChangeSet).files)) return undefined;
  const raw = value as Record<string, unknown>;
  const files = (raw.files as unknown[]).flatMap((entry): ChangedFile[] => {
    const file = entry as Record<string, unknown> | null;
    const path = text(file?.path);
    if (!file || !path) return [];
    const status = STATUSES.has(file.status as ChangedFile["status"])
      ? (file.status as ChangedFile["status"])
      : "modified";
    return [
      {
        path,
        previousPath: text(file.previousPath),
        status,
        additions: count(file.additions),
        deletions: count(file.deletions),
        patch: text(file.patch),
        binary: file.binary === true,
      },
    ];
  });
  return {
    scope,
    root: text(raw.root),
    head: text(raw.head),
    base: text(raw.base),
    files,
    additions: count(raw.additions),
    deletions: count(raw.deletions),
    untrackedSkipped: count(raw.untrackedSkipped),
    totalFiles: count(raw.totalFiles),
    filesOmitted: count(raw.filesOmitted),
  };
}

/// A unified patch's hunks, numbered from their `@@` headers. Each hunk reads as many
/// lines as its header counts, so a blank context line whose space was trimmed in transit
/// still counts, and anything after the hunk ("\ No newline at end of file") does not.
export function patchHunks(patch: string | undefined): DiffHunk[] {
  const hunks: DiffHunk[] = [];
  let lines: DiffLine[] = [];
  let oldLine = 0;
  let newLine = 0;
  let oldLeft = 0;
  let newLeft = 0;
  const rows = (patch ?? "").split("\n");
  // The patch's final newline ends its last line; it does not start a blank one.
  if (rows.at(-1) === "") rows.pop();
  for (const raw of rows) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
    if (header) {
      lines = [];
      hunks.push({ lines });
      oldLine = Number(header[1]);
      oldLeft = header[2] === undefined ? 1 : Number(header[2]);
      newLine = Number(header[3]);
      newLeft = header[4] === undefined ? 1 : Number(header[4]);
    } else if (oldLeft <= 0 && newLeft <= 0) continue;
    else if (line.startsWith("+") && newLeft > 0) {
      lines.push({ type: "add", text: line.slice(1), newLine: newLine++ });
      newLeft -= 1;
    } else if (line.startsWith("-") && oldLeft > 0) {
      lines.push({ type: "del", text: line.slice(1), oldLine: oldLine++ });
      oldLeft -= 1;
    } else if ((line.startsWith(" ") || line === "") && oldLeft > 0 && newLeft > 0) {
      lines.push({ type: "context", text: line.slice(1), oldLine: oldLine++, newLine: newLine++ });
      oldLeft -= 1;
      newLeft -= 1;
    }
  }
  return hunks;
}

/// A scope's files as the view's files: one edit each, with the patch's line numbers.
export function changeSetFiles(changeSet: ChangeSet): TurnFile[] {
  const root = changeSet.root?.replace(/\/+$/, "");
  return changeSet.files.map((file) => ({
    path: root ? `${root}/${file.path}` : file.path,
    displayPath: file.path,
    edits: [{ toolId: changeSet.scope, hunks: file.binary ? [] : patchHunks(file.patch), numbered: true }],
    additions: file.additions,
    deletions: file.deletions,
    created: file.status === "added" || file.status === "untracked",
    deleted: file.status === "deleted",
    binary: file.binary,
  }));
}
