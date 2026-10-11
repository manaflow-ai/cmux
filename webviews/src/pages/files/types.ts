// The Files page's ops (`cmux.files.*`, CmuxNextApp FilesPageProvider). Paths are relative to the
// tab's folder, '/'-separated, "" for the folder itself; the page never sends an absolute path.

export const FilesOps = {
  /** `{}` → `RootInfo`: the folder this tab shows. */
  root: "cmux.files.root",
  /** `{path}` → `Listing`: one folder's children, as git sees them (ignored files hidden). */
  list: "cmux.files.list",
  /** `{path}`: opens a file in the editor beside the tree. */
  open: "cmux.files.open",
} as const;

/** The native UI op for the pasteboard, when the page origin cannot use the async clipboard. */
export const CLIPBOARD_WRITE = "cmux.app.clipboard.write";

export type EntryKind = "file" | "directory";

export interface FileEntry {
  name: string;
  kind: EntryKind;
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
