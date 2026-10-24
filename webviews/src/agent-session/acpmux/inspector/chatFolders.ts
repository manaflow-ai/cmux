// The folders a chat worked in, as Claude Code desktop's Environment lists them: the chat's own
// folder first, then each project folder its tool calls touched, in the order it first touched
// them. A tool call names files (an edit's diffs, a read's locations) and folders (a command's
// `cd DIR` or `git -C DIR`). Each path counts as its project: inside a repository folder (the chat
// folder with a branch) it is that folder; inside a plain folder, the child folder it is in (a
// chat in ~/Projects that edits ~/Projects/cmux/src/a.ts touched `cmux`); elsewhere in the home
// folder, the folder beside the chat folder's line it is in (from ~/Projects/cmux, an edit of
// ~/Projects/glaeda/x.go touched `glaeda`); outside the home folder, the file's own folder.
// Temporary and hidden folders (the agent's scratch space, ~/.claude) are left out.
import type { AcpmuxRow } from "../model";

const HOME = /^\/(?:Users|home)\/[^/]+(?=\/|$)/;
const SCRATCH = /^\/(?:tmp|private\/tmp|private\/var|var\/folders)(?:\/|$)/;
/// `cd DIR` and `git -C DIR`, DIR absolute or from the home folder, bare or quoted.
const COMMAND_FOLDER = /(?:^|[\s;&|(])(?:cd|git\s+-C)\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|)]+))/g;

/// A path a tool call named: a file (an edit's diff, a read's location) or a folder (a command's
/// `cd` or `git -C`).
type Touched = { readonly path: string; readonly isFile: boolean };

/// Each row's paths in call order, kept while the row is the same object (a streamed update
/// replaces only the live row).
const rowPaths = new WeakMap<AcpmuxRow, Touched[]>();

const parts = (path: string) => path.split("/").filter(Boolean);
const join = (segments: readonly string[]) => `/${segments.join("/")}`;
const trim = (path: string) => (path.length > 1 ? path.replace(/\/+$/, "") : path);

function pathsOf(row: AcpmuxRow, home: string | undefined): Touched[] {
  const cached = rowPaths.get(row);
  if (cached) return cached;
  const touched: Touched[] = [];
  for (const item of row.items ?? []) {
    const tool = item.tool;
    if (!tool) continue;
    for (const diff of tool.diffs ?? []) touched.push({ path: diff.path, isFile: true });
    for (const location of tool.locations ?? []) touched.push({ path: location.path, isFile: true });
    for (const match of tool.command?.matchAll(COMMAND_FOLDER) ?? []) {
      const raw = match[1] ?? match[2] ?? match[3] ?? "";
      const folder = raw.startsWith("~/") || raw === "~" ? (home ? home + raw.slice(1) : undefined) : raw;
      if (folder?.startsWith("/")) touched.push({ path: folder, isFile: false });
    }
  }
  rowPaths.set(row, touched);
  return touched;
}

/// The project folder `path` belongs to, seen from the chat folder; undefined to leave it out.
export function projectFolder(
  path: string,
  isFile: boolean,
  cwd: string | undefined,
  repository: boolean,
): string | undefined {
  const clean = trim(path);
  if (!clean.startsWith("/") || SCRATCH.test(clean)) return undefined;
  const segments = parts(clean);
  const folder = isFile ? segments.slice(0, -1) : segments;
  const home = clean.match(HOME)?.[0];
  if (cwd) {
    const base = parts(trim(cwd));
    const inside = base.every((segment, index) => folder[index] === segment);
    if (inside) {
      // In the chat folder: a repository is one project; a plain folder's child folders are each one.
      if (repository || folder.length === base.length) return trim(cwd);
      return hidden(folder[base.length]) ? undefined : join(folder.slice(0, base.length + 1));
    }
    if (home && clean.startsWith(`${home}/`) && trim(cwd).startsWith(`${home}/`)) {
      // In the home folder: the folder beside the chat folder's line, where the two paths part.
      let shared = 0;
      while (shared < base.length && folder[shared] === base[shared]) shared++;
      if (shared >= folder.length || hidden(folder[shared])) return undefined;
      return join(folder.slice(0, shared + 1));
    }
  }
  if (home && parts(home).length >= folder.length) return undefined;
  return folder.some(hidden) ? undefined : join(folder);
}

const hidden = (segment: string | undefined) => segment === undefined || segment.startsWith(".");

/// The chat's folders: its own first, then each project folder its tool calls touched, once.
export function chatFolders(rows: readonly AcpmuxRow[], cwd: string | undefined, repository: boolean): string[] {
  const home = cwd?.match(HOME)?.[0];
  const seen = new Set<string>();
  const folders: string[] = [];
  const add = (folder: string | undefined) => {
    if (!folder || seen.has(folder)) return;
    seen.add(folder);
    folders.push(folder);
  };
  if (cwd) add(trim(cwd));
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const { path, isFile } of pathsOf(row, home)) add(projectFolder(path, isFile, cwd, repository));
  }
  return folders;
}
