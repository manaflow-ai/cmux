// The Files page's ops (`cmux.files.*`, CmuxNextApp FilesPageProvider). Paths are relative to the
// tab's folder, '/'-separated, "" for the folder itself; the page never sends an absolute path.

export const FilesOps = {
  /** `{}` → `RootInfo`: the folder this tab shows. */
  root: "cmux.files.root",
  /** `{path}` → `Listing`: one folder's children, as git sees them, then what git ignores (`ignored`). */
  list: "cmux.files.list",
  /** `{path}`: opens a file in the editor beside the tree. */
  open: "cmux.files.open",
  /** `{query}` → `SearchResults`: files under the folder whose path matches, best first. */
  search: "cmux.files.search",
} as const;

/** The native UI op for the pasteboard, when the page origin cannot use the async clipboard. */
export const CLIPBOARD_WRITE = "cmux.app.clipboard.write";

export type EntryKind = "file" | "directory";

export interface FileEntry {
  name: string;
  kind: EntryKind;
  /** Git ignores it: listed from the folder on disk, drawn greyed out. */
  ignored?: boolean;
}

export interface SearchResults {
  /** Paths relative to the tab's folder. */
  results: { path: string }[];
}

export interface RootInfo {
  /** The folder's absolute path, for Copy Path and the header's tooltip. */
  folder: string;
  /** Its last path component. */
  name: string;
}

export interface Listing {
  entries: FileEntry[];
  /** The folder has more children than the page was sent. */
  truncated: boolean;
}
