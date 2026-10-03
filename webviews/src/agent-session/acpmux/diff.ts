import type { AcpmuxActivity, AcpmuxFileDiff, AcpmuxRow } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type DiffLine = { type: "context" | "add" | "del"; text: string; oldLine?: number; newLine?: number };
export type DiffHunk = {
  lines: DiffLine[];
  /// Checkpoint hunks can point back to the tool hunks that produced them. The tool view leaves
  /// this unset and uses its own hunkKey as the review identity.
  reviewKeys?: string[];
};
/// One tool call's change to a file. Line numbers are known for a new file, a file the agent
/// sent whole, or an edit whose tool call located its first line; a bare fragment has none.
export type DiffEdit = { toolId: string; hunks: DiffHunk[]; numbered: boolean };
export type TurnFile = {
  path: string;
  displayPath: string;
  edits: DiffEdit[];
  additions: number;
  deletions: number;
  created: boolean;
  /// A git scope's file that the change removed, or whose contents are not text.
  deleted?: boolean;
  binary?: boolean;
  /// A turn checkpoint's file that none of the turn's tool calls changed: read-only.
  outside?: boolean;
  /// The host returned only part of this file's patch, so hunk review is unsafe.
  patchTruncated?: boolean;
};

/// Lines unchanged around a change that a hunk keeps, as `git diff` does.
const CONTEXT_LINES = 3;
/// Past this many edit steps a file diffs as one replacement, so a rewritten large file
/// cannot stall the pane.
const MAX_EDIT_STEPS = 1_000;

export function splitLines(text: string | undefined | null): string[] {
  if (!text) return [];
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines.map((line) => (line.endsWith("\r") ? line.slice(0, -1) : line));
}

type Op = { type: "context" | "add" | "del"; text: string };

/// Myers' O(ND) line diff of the lines between a shared prefix and suffix.
function myers(a: string[], b: string[]): Op[] | undefined {
  const n = a.length;
  const m = b.length;
  const max = Math.min(n + m, MAX_EDIT_STEPS);
  const offset = max + 1;
  const v = new Int32Array(2 * max + 3);
  const trace: Int32Array[] = [];
  for (let d = 0; d <= max; d += 1) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x =
        k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x += 1;
        y += 1;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) return backtrack(trace, a, b, offset, d);
    }
  }
  return undefined;
}

function backtrack(trace: Int32Array[], a: string[], b: string[], offset: number, steps: number): Op[] {
  const ops: Op[] = [];
  let x = a.length;
  let y = b.length;
  for (let d = steps; d > 0; d -= 1) {
    const v = trace[d];
    const k = x - y;
    const down = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]);
    const previousK = down ? k + 1 : k - 1;
    const previousX = v[offset + previousK];
    const previousY = previousX - previousK;
    while (x > previousX && y > previousY) {
      x -= 1;
      y -= 1;
      ops.push({ type: "context", text: a[x] });
    }
    if (down) {
      y -= 1;
      ops.push({ type: "add", text: b[y] });
    } else {
      x -= 1;
      ops.push({ type: "del", text: a[x] });
    }
  }
  while (x > 0 && y > 0) {
    x -= 1;
    y -= 1;
    ops.push({ type: "context", text: a[x] });
  }
  return ops.reverse();
}

export function diffLines(oldText: string | undefined | null, newText: string | undefined | null): Op[] {
  const a = splitLines(oldText);
  const b = splitLines(newText);
  let prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix += 1;
  let suffix = 0;
  while (
    suffix < a.length - prefix &&
    suffix < b.length - prefix &&
    a[a.length - 1 - suffix] === b[b.length - 1 - suffix]
  )
    suffix += 1;
  const middleA = a.slice(prefix, a.length - suffix);
  const middleB = b.slice(prefix, b.length - suffix);
  const middle = myers(middleA, middleB) ?? [
    ...middleA.map((text) => ({ type: "del" as const, text })),
    ...middleB.map((text) => ({ type: "add" as const, text })),
  ];
  return [
    ...a.slice(0, prefix).map((text) => ({ type: "context" as const, text })),
    ...middle,
    ...a.slice(a.length - suffix).map((text) => ({ type: "context" as const, text })),
  ];
}

/// Groups a diff into hunks with `CONTEXT_LINES` of context, numbering lines from `firstLine`.
export function diffHunks(ops: Op[], firstLine = 1, context = CONTEXT_LINES): DiffHunk[] {
  const numbered: DiffLine[] = [];
  let oldLine = firstLine;
  let newLine = firstLine;
  for (const op of ops) {
    if (op.type === "context") numbered.push({ ...op, oldLine: oldLine++, newLine: newLine++ });
    else if (op.type === "del") numbered.push({ ...op, oldLine: oldLine++ });
    else numbered.push({ ...op, newLine: newLine++ });
  }
  const changed = numbered.flatMap((line, index) => (line.type === "context" ? [] : [index]));
  const hunks: DiffHunk[] = [];
  let start = -1;
  let end = -1;
  for (const index of changed) {
    if (start >= 0 && index - context <= end + 1) {
      end = Math.min(numbered.length - 1, index + context);
      continue;
    }
    if (start >= 0) hunks.push({ lines: numbered.slice(start, end + 1) });
    start = Math.max(0, index - context);
    end = Math.min(numbered.length - 1, index + context);
  }
  if (start >= 0) hunks.push({ lines: numbered.slice(start, end + 1) });
  return hunks;
}

/// The rows of the turn `rowId` belongs to: from its user message up to the next one.
export function turnRows(rows: AcpmuxRow[], rowId: string): AcpmuxRow[] {
  const index = rows.findIndex((row) => row.id === rowId);
  if (index < 0) return [];
  let start = index;
  while (start > 0 && rows[start].kind !== "user") start -= 1;
  let end = index + 1;
  while (end < rows.length && rows[end].kind !== "user") end += 1;
  return rows.slice(start, end);
}

function commonDirectory(paths: string[]): string {
  if (paths.length === 0) return "";
  const split = paths.map((path) => path.split("/").slice(0, -1));
  let shared = 0;
  while (split.every((parts) => shared < parts.length && parts[shared] === split[0][shared])) shared += 1;
  return shared ? `${split[0].slice(0, shared).join("/")}/` : "";
}

/// Every file the turn's tool calls changed, in the order first changed, each edit in turn.
export function turnFiles(rows: AcpmuxRow[]): TurnFile[] {
  return toolFiles(
    rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool ?? []) : [])),
  );
}

/// The files these tool calls changed, each edit in turn, named from their shared directory.
export function toolFiles(tools: readonly Tool[]): TurnFile[] {
  const files = new Map<string, TurnFile>();
  for (const tool of tools)
    for (const change of tool.diffs ?? []) {
      let file = files.get(change.path);
      if (!file) {
        file = {
          path: change.path,
          displayPath: change.path,
          edits: [],
          additions: 0,
          deletions: 0,
          created: change.oldText == null,
        };
        files.set(change.path, file);
      }
      file.edits.push(fileEdit(tool.id, change));
    }
  const list = [...files.values()];
  const base = commonDirectory(list.map((file) => file.path));
  for (const file of list) {
    file.displayPath = file.path.slice(base.length);
    for (const edit of file.edits)
      for (const hunk of edit.hunks)
        for (const line of hunk.lines) {
          if (line.type === "add") file.additions += 1;
          else if (line.type === "del") file.deletions += 1;
        }
  }
  return list;
}

function fileEdit(toolId: string, change: AcpmuxFileDiff): DiffEdit {
  const numbered = change.oldText == null || change.line !== undefined;
  return { toolId, hunks: diffHunks(diffLines(change.oldText, change.newText), change.line ?? 1), numbered };
}

/// One edit as a unified patch Pierre can render, with the edit's hunks and line numbers.
export function editPatch(file: TurnFile, edit: DiffEdit): string {
  const name = file.displayPath;
  const lines = [
    `diff --git a/${name} b/${name}`,
    file.created ? "--- /dev/null" : `--- a/${name}`,
    file.deleted ? "+++ /dev/null" : `+++ b/${name}`,
  ];
  for (const hunk of edit.hunks) {
    const oldLines = hunk.lines.filter((line) => line.type !== "add");
    const newLines = hunk.lines.filter((line) => line.type !== "del");
    const oldStart = oldLines[0]?.oldLine ?? Math.max(0, (newLines[0]?.newLine ?? 1) - 1);
    const newStart = newLines[0]?.newLine ?? Math.max(0, (oldLines[0]?.oldLine ?? 1) - 1);
    lines.push(`@@ -${oldStart},${oldLines.length} +${newStart},${newLines.length} @@`);
    for (const line of hunk.lines)
      lines.push(`${line.type === "add" ? "+" : line.type === "del" ? "-" : " "}${line.text}`);
  }
  return `${lines.join("\n")}\n`;
}

/// A hunk's identity within a turn: the tool call, its file, which of that call's edits to the
/// file it is in, and its place in that edit. Counting within the call keeps the key when an
/// earlier call's diff arrives late.
export const hunkKey = (file: TurnFile, editIndex: number, hunkIndex: number) => {
  const toolId = file.edits[editIndex]!.toolId;
  const inCall = file.edits.slice(0, editIndex).filter((edit) => edit.toolId === toolId).length;
  return `${toolId}\u0000${file.path}\u0000${inCall}\u0000${hunkIndex}`;
};

/// One hunk as unified diff text, under the full path the tool call reported, so the agent
/// finds the file. Ranges use the edit's line numbers when they are known; a bare fragment
/// has none, and its context lines place it.
export function hunkPatch(file: TurnFile, edit: DiffEdit, hunk: DiffHunk): string {
  const oldLines = hunk.lines.filter((line) => line.type !== "add");
  const newLines = hunk.lines.filter((line) => line.type !== "del");
  const range = (lines: DiffLine[], key: "oldLine" | "newLine") => `${lines[0]?.[key] ?? 0},${lines.length}`;
  const header = edit.numbered ? `@@ -${range(oldLines, "oldLine")} +${range(newLines, "newLine")} @@` : "@@";
  const body = hunk.lines.map((line) => `${line.type === "add" ? "+" : line.type === "del" ? "-" : " "}${line.text}`);
  return [`--- ${file.path}`, `+++ ${file.path}`, header, ...body].join("\n");
}

/// The prompt that asks the agent to undo the hunks the reader rejected and keep the rest.
export function rejectionPrompt(patches: string[], note?: string): string {
  const intro =
    patches.length === 1
      ? "I reviewed your changes and rejected this one. Please revert it and keep your other changes:"
      : `I reviewed your changes and rejected these ${patches.length}. Please revert them and keep your other changes:`;
  // A fence longer than any backtick run in the patches, so code containing one cannot close it.
  const longest = Math.max(
    0,
    ...patches.map((patch) => Math.max(0, ...(patch.match(/`+/g) ?? []).map((run) => run.length))),
  );
  const fence = "`".repeat(Math.max(3, longest + 1));
  return [intro, "", `${fence}diff`, patches.join("\n"), fence, ...(note?.trim() ? ["", note.trim()] : [])].join("\n");
}
