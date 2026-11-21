// A new chat's extra folders: the folders it sees beside its own (acpmux `session/new`
// `additionalDirectories`, cmux#32811). Leo, 2026-11-03: "being able to have chatgpt (and in this
// case, any harnesses) see whatever folders/files would be cool" and "and you can also just start
// with nothing". The project stays the chat's cwd; with no project the chat starts in its private
// folder and these sit beside it. The paths are the machine's the chat runs on, so a list belongs
// to one machine: a pick of another machine starts over.

/// The most folders acpmux takes for one chat (hub/additional_dirs.rs `MAX_DIRS`).
export const MAX_EXTRA_FOLDERS = 64;

/// The folders a new chat holds before its first send, and the machine they are on (`local` for
/// this Mac, else the peer or Cloud machine's id, as the composer's machine control names it).
export type ExtraFolderDraft = { machine: string; folders: readonly string[] };

/// What the composer's folder menu needs to list, add and remove a new chat's extra folders.
export type ExtraFolderRows = {
  folders: readonly string[];
  onAdd(path: string): void;
  onRemove(path: string): void;
  /// The machine's folder chooser (this Mac's native panel); its pick is added. None on a machine
  /// whose folders are only listed (a peer): the menu's rows and a typed path add one there.
  onBrowse?(): Promise<string | undefined> | string | undefined | void;
};

const NONE: readonly string[] = [];

/// `path` without trailing slashes (`/` stays `/`).
export function trimFolder(path: string): string {
  const trimmed = path.trim().replace(/\/+$/, "");
  return trimmed || (path.trim().startsWith("/") ? "/" : trimmed);
}

/// An absolute path acpmux can take: starts with `/`, no NUL, not just `/`.
export function isExtraFolderPath(path: string): boolean {
  const folder = trimFolder(path);
  return folder.startsWith("/") && folder !== "/" && !folder.includes("\0");
}

/// `folders` with `path` added at the end: absolute, without trailing slashes, each once, never the
/// chat's own folder `cwd`, at most ``MAX_EXTRA_FOLDERS``. Returns `folders` itself when nothing changed.
export function addExtraFolder(folders: readonly string[], path: string, cwd?: string): readonly string[] {
  if (!isExtraFolderPath(path)) return folders;
  const folder = trimFolder(path);
  if (folders.length >= MAX_EXTRA_FOLDERS) return folders;
  if (folders.includes(folder) || (cwd !== undefined && trimFolder(cwd) === folder)) return folders;
  return [...folders, folder];
}

/// `folders` without `path`. Returns `folders` itself when it was not there.
export function removeExtraFolder(folders: readonly string[], path: string): readonly string[] {
  const folder = trimFolder(path);
  return folders.includes(folder) ? folders.filter((candidate) => candidate !== folder) : folders;
}

/// The draft's folders while `machine` is the one picked; none for another machine (its paths
/// mean nothing there) or without a draft.
export function draftFolders(draft: ExtraFolderDraft | undefined, machine: string): readonly string[] {
  return draft && draft.machine === machine ? draft.folders : NONE;
}

/// The `additionalDirectories` of a `session/new` in `cwd`: the folders other than `cwd`, valid and
/// each once; undefined for none, so the field is left out.
export function extraFoldersParam(folders: readonly string[] | undefined, cwd?: string): string[] | undefined {
  if (!folders?.length) return undefined;
  let out: readonly string[] = [];
  for (const folder of folders) out = addExtraFolder(out, folder, cwd);
  return out.length > 0 ? [...out] : undefined;
}

/// The folders a session summary lists beside its own (acpmux `additionalDirectories`,
/// hub/views.rs). The same array when it is already a clean list of strings, so a snapshot
/// that did not change it keeps its identity; undefined for none or a malformed field.
export function summaryExtraFolders(value: unknown): readonly string[] | undefined {
  if (!Array.isArray(value) || value.length === 0) return undefined;
  if (value.every((item) => typeof item === "string" && item.length > 0)) return value as string[];
  const clean = value.filter((item): item is string => typeof item === "string" && item.length > 0);
  return clean.length > 0 ? clean : undefined;
}

/// A folder's name for a row: its last path component.
export function extraFolderName(path: string): string {
  const folder = trimFolder(path);
  return folder.slice(folder.lastIndexOf("/") + 1) || folder;
}

/// What a surface hands the composer's folder control for a new chat's extra folders: the draft,
/// its change, and this Mac's folder chooser (ComposerContext `extraFolders`).
export type ExtraFolderControl = {
  draft?: ExtraFolderDraft;
  onChange(next: ExtraFolderDraft | undefined): void;
  onBrowse?(): Promise<string | undefined> | string | undefined | void;
};

/// The draft as the pane's client sees it: folders of the pane's own machine (`paneMachine`, the
/// composer's name for a pane that runs on a Cloud or peer machine) are `local` to it, since a
/// start there names no peer.
export function ownMachineFolders(
  draft: ExtraFolderDraft | undefined,
  paneMachine: string,
): ExtraFolderDraft | undefined {
  return draft && draft.machine === paneMachine ? { ...draft, machine: "local" } : draft;
}
