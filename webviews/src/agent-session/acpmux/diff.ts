import {
  contentsUnknown,
  pathKey,
  plainEditLabels,
  type AcpmuxActivity,
  type AcpmuxFileDiff,
  type AcpmuxRow,
} from "./model";
import { opensTurn } from "./turnStart";

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
  /// The file's canonical path (model.ts `pathKey`): what acpmux recorded for a tool call's file,
  /// or a turn checkpoint's `${root}/${path}`. Absent for a path recorded without one.
  canonical?: string;
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
  /// The raw git patch when a scope supplied one, used to share blob identity with the full viewer.
  patch?: string;
  /// Git's content identity, supplied for hunk-only and binary native responses.
  blobFingerprint?: string;
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

/// The rows of the turn `rowId` belongs to: from its user message up to the next one. A steer goes
/// on with the turn (turnStart.ts), so the turn runs past it.
export function turnRows(rows: AcpmuxRow[], rowId: string): AcpmuxRow[] {
  const index = rows.findIndex((row) => row.id === rowId);
  if (index < 0) return [];
  let start = index;
  while (start > 0 && !opensTurn(rows[start])) start -= 1;
  let end = index + 1;
  while (end < rows.length && !opensTurn(rows[end])) end += 1;
  return rows.slice(start, end);
}

/// A summary that ends the turn. A turn a prompt sent now stopped goes on under that prompt
/// (direct.ts `continued`): its summary ends only that part, and the turn ends with a later one.
export const endsTurn = (row: AcpmuxRow) => row.kind === "turnSummary" && !row.continued;

/// The directory `paths` share, with its trailing slash ("" for none): what a file's displayed path
/// leaves out (`toolFiles` `displayPath`).
export function commonDirectory(paths: string[]): string {
  if (paths.length === 0) return "";
  const split = paths.map((path) => path.split("/").slice(0, -1));
  let shared = 0;
  while (split.every((parts) => shared < parts.length && parts[shared] === split[0][shared])) shared += 1;
  return shared ? `${split[0].slice(0, shared).join("/")}/` : "";
}

/// Every file the turn's tool calls changed, in the order first changed, each edit in turn. A file a
/// Write rewrote with old contents unknown (model.ts `contentsUnknown`) is left out, with any other
/// edit to it, so nothing counts, diffs or undoes it: the edited-files card lists its path without
/// counts (`plainEditLabels`).
export function turnFiles(rows: AcpmuxRow[]): TurnFile[] {
  return toolFiles(
    rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool ?? []) : [])),
    { known: true },
  );
}

/// The last activity row whose tool calls changed the file at `path` (one of its spellings: the same
/// canonical path, model.ts `pathKey`), and the file's path in that row's turn, where its diff opens.
/// Undefined when no diff names it.
export function lastChange(rows: readonly AcpmuxRow[], path: string): { rowId: string; path: string } | undefined {
  const diffs = (row: AcpmuxRow) =>
    row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool?.diffs ?? []) : [];
  const canonical = rows.flatMap(diffs).find((diff) => diff.path === path && diff.canonical)?.canonical;
  const isIt = (file: PathRef) => file.path === path || (canonical !== undefined && file.canonical === canonical);
  const row = [...rows].reverse().find((candidate) => diffs(candidate).some(isIt));
  if (!row) return undefined;
  const file = turnFiles(turnRows([...rows], row.id)).find(isIt);
  return { rowId: row.id, path: file?.path ?? path };
}

/// The paths the turn's edits changed with no diff `turnFiles` counts: an edit whose call carried
/// none, and a file a Write rewrote with old contents unknown. A checkpoint file at one of them is
/// still a tool call's change (turnCheckpoint.ts `turnDisplay`), not one made outside them. Not a
/// path only failed calls named: they changed nothing (the card still lists it, as failed).
export function turnPathsOnly(rows: readonly AcpmuxRow[]): PathRef[] {
  const edits = rows.flatMap((row) =>
    row.kind === "activity"
      ? (row.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange")
      : [],
  );
  return plainEditLabels(edits).flatMap(({ path, canonical, failed }) =>
    path && !failed ? [canonical ? { path, canonical } : { path }] : [],
  );
}

/// A tool call's path as the agent wrote it, with its canonical path when acpmux recorded one.
export type PathRef = { path: string; canonical?: string };

/// The files these tool calls changed, each edit in turn, named from their shared directory.
/// `known`: without a file a Write rewrote with old contents unknown, whose net change is unknown
/// whatever else edited it; such a Write that failed wrote nothing, so it neither counts nor hides
/// its file. One call's own view (its transcript row, a permission ask) still shows the text such a
/// Write wrote.
export function toolFiles(tools: readonly Tool[], { known = false }: { known?: boolean } = {}): TurnFile[] {
  // An edit still waiting for its permission has changed nothing yet.
  const changes = (tool: Tool) => (tool.status === "pending" ? [] : (tool.diffs ?? []));
  const unknown = new Set(
    known
      ? tools.flatMap((tool) =>
          tool.status === "failed"
            ? []
            : changes(tool).flatMap((change) => (contentsUnknown(change) ? [pathKey(change)] : [])),
        )
      : [],
  );
  // One file per canonical path (model.ts `pathKey`), under the spelling its first edit used.
  const files = new Map<string, TurnFile>();
  for (const tool of tools)
    for (const change of changes(tool)) {
      const key = pathKey(change);
      if (unknown.has(key) || (known && tool.status === "failed" && contentsUnknown(change))) continue;
      let file = files.get(key);
      if (!file) {
        file = {
          path: change.path,
          ...(change.canonical ? { canonical: change.canonical } : {}),
          displayPath: change.path,
          edits: [],
          additions: 0,
          deletions: 0,
          // A fragment has no whole-file text, so a missing old text is not proof of a new file.
          created: change.oldText == null && !change.fragment,
        };
        files.set(key, file);
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
  return [intro, "", ...fencedPatches(patches), ...(note?.trim() ? ["", note.trim()] : [])].join("\n");
}

/// The prompt behind a turn's Undo: revert everything the turn changed.
export function undoPrompt(patches: string[]): string {
  return [
    "Please undo the changes you made in that turn, so these files read as they did before it:",
    "",
    ...fencedPatches(patches),
  ].join("\n");
}

/// The patches in one diff fence, longer than any backtick run in them so code containing one
/// cannot close it.
function fencedPatches(patches: string[]): string[] {
  const longest = Math.max(
    0,
    ...patches.map((patch) => Math.max(0, ...(patch.match(/`+/g) ?? []).map((run) => run.length))),
  );
  const fence = "`".repeat(Math.max(3, longest + 1));
  return [`${fence}diff`, patches.join("\n"), fence];
}
