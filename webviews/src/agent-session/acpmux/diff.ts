import type { AcpmuxFileDiff, AcpmuxRow } from "./model";

export type DiffLine = { type: "context" | "add" | "del"; text: string; oldLine?: number; newLine?: number };
export type DiffHunk = { lines: DiffLine[] };
/// One tool call's change to a file. Line numbers are known for a new file, a file the agent
/// sent whole, or an edit whose tool call located its first line; a bare fragment has none.
export type DiffEdit = { toolId: string; hunks: DiffHunk[]; numbered: boolean };
export type TurnFile = { path: string; displayPath: string; edits: DiffEdit[]; additions: number; deletions: number; created: boolean };
export type SplitCell = { line?: number; text: string; type: "context" | "add" | "del" | "empty" };
export type SplitRow = { left: SplitCell; right: SplitCell };
export type FileTreeNode = { name: string; path: string; file?: TurnFile; children: FileTreeNode[] };

/// Lines unchanged around a change that a hunk keeps, as `git diff` does.
const CONTEXT_LINES = 3;
/// Past this many edit steps a file diffs as one replacement, so a rewritten large file
/// cannot stall the pane.
const MAX_EDIT_STEPS = 1_000;

export function splitLines(text: string | undefined | null): string[] {
  if (!text) return [];
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines.map((line) => line.endsWith("\r") ? line.slice(0, -1) : line);
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
      let x = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) { x += 1; y += 1; }
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
    while (x > previousX && y > previousY) { x -= 1; y -= 1; ops.push({ type: "context", text: a[x] }); }
    if (down) { y -= 1; ops.push({ type: "add", text: b[y] }); } else { x -= 1; ops.push({ type: "del", text: a[x] }); }
  }
  while (x > 0 && y > 0) { x -= 1; y -= 1; ops.push({ type: "context", text: a[x] }); }
  return ops.reverse();
}

export function diffLines(oldText: string | undefined | null, newText: string | undefined | null): Op[] {
  const a = splitLines(oldText);
  const b = splitLines(newText);
  let prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix += 1;
  let suffix = 0;
  while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix += 1;
  const middleA = a.slice(prefix, a.length - suffix);
  const middleB = b.slice(prefix, b.length - suffix);
  const middle = myers(middleA, middleB) ?? [...middleA.map((text) => ({ type: "del" as const, text })), ...middleB.map((text) => ({ type: "add" as const, text }))];
  return [...a.slice(0, prefix).map((text) => ({ type: "context" as const, text })), ...middle, ...a.slice(a.length - suffix).map((text) => ({ type: "context" as const, text }))];
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
  const changed = numbered.flatMap((line, index) => line.type === "context" ? [] : [index]);
  const hunks: DiffHunk[] = [];
  let start = -1;
  let end = -1;
  for (const index of changed) {
    if (start >= 0 && index - context <= end + 1) { end = Math.min(numbered.length - 1, index + context); continue; }
    if (start >= 0) hunks.push({ lines: numbered.slice(start, end + 1) });
    start = Math.max(0, index - context);
    end = Math.min(numbered.length - 1, index + context);
  }
  if (start >= 0) hunks.push({ lines: numbered.slice(start, end + 1) });
  return hunks;
}

/// Lays a hunk out side by side: a run of removed lines pairs with the added lines after it.
export function splitRows(hunk: DiffHunk): SplitRow[] {
  const rows: SplitRow[] = [];
  const empty: SplitCell = { text: "", type: "empty" };
  let index = 0;
  const lines = hunk.lines;
  while (index < lines.length) {
    const line = lines[index];
    if (line.type === "context") { rows.push({ left: { line: line.oldLine, text: line.text, type: "context" }, right: { line: line.newLine, text: line.text, type: "context" } }); index += 1; continue; }
    const dels: DiffLine[] = [];
    const adds: DiffLine[] = [];
    while (index < lines.length && lines[index].type === "del") dels.push(lines[index++]);
    while (index < lines.length && lines[index].type === "add") adds.push(lines[index++]);
    for (let row = 0; row < Math.max(dels.length, adds.length); row += 1) {
      const del = dels[row];
      const add = adds[row];
      rows.push({ left: del ? { line: del.oldLine, text: del.text, type: "del" } : empty, right: add ? { line: add.newLine, text: add.text, type: "add" } : empty });
    }
  }
  return rows;
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
  const files = new Map<string, TurnFile>();
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      for (const change of item.tool?.diffs ?? []) {
        let file = files.get(change.path);
        if (!file) { file = { path: change.path, displayPath: change.path, edits: [], additions: 0, deletions: 0, created: change.oldText == null }; files.set(change.path, file); }
        file.edits.push(fileEdit(item.tool!.id, change));
      }
    }
  }
  const list = [...files.values()];
  const base = commonDirectory(list.map((file) => file.path));
  for (const file of list) {
    file.displayPath = file.path.slice(base.length);
    for (const edit of file.edits) for (const hunk of edit.hunks) for (const line of hunk.lines) {
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

/// Files as a directory tree; a directory with a single child directory folds into it ("src/app").
export function fileTree(files: TurnFile[]): FileTreeNode[] {
  const root: FileTreeNode = { name: "", path: "", children: [] };
  for (const file of files) {
    const parts = file.displayPath.split("/");
    let node = root;
    parts.forEach((part, index) => {
      const path = parts.slice(0, index + 1).join("/");
      const leaf = index === parts.length - 1;
      let child = node.children.find((entry) => entry.name === part && Boolean(entry.file) === leaf);
      if (!child) { child = { name: part, path, children: [], file: leaf ? file : undefined }; node.children.push(child); }
      node = child;
    });
  }
  const fold = (node: FileTreeNode): FileTreeNode => {
    let current = node;
    while (!current.file && current.children.length === 1 && !current.children[0].file) {
      const only = current.children[0];
      current = { ...only, name: `${current.name}/${only.name}` };
    }
    return { ...current, children: order(current.children.map(fold)) };
  };
  const order = (nodes: FileTreeNode[]) => nodes.sort((a, b) => Number(Boolean(a.file)) - Number(Boolean(b.file)) || a.name.localeCompare(b.name));
  return order(root.children.map(fold));
}
