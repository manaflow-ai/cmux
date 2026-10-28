// The Files page's ops (`cmux.files.*`, CmuxNextApp FilesPageProvider). Paths are relative to the
// tab's folder, '/'-separated, "" for the folder itself; the page never sends an absolute path.

export const FilesOps = {
  /** `{}` → `RootInfo`: the folder this tab shows. */
  root: "cmux.files.root",
  /** `{path}` → `Listing`: one folder's children, as git sees them (ignored files hidden). */
  list: "cmux.files.list",
  /** `{path}`: opens a file in the editor beside the tree. */
  open: "cmux.files.open",
  /** Host to page, `{}` → `FilesViewState`: what the tree shows, asked right before the host discards
   * the hidden page; the next page gets it back once in `RootInfo.viewState`. */
  viewState: "cmux.files.viewState",
} as const;

/** The open folders, the selected row and the scroll of a Files tree whose page was discarded. */
export interface FilesViewState {
  expanded: string[];
  selected?: string;
  scroll: number;
}

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
  /** What a discarded page of this tab showed, sent once (unchecked: `filesViewStateOf`). */
  viewState?: unknown;
}

/** A `viewState` from the host, or null when it is not one. */
export function filesViewStateOf(value: unknown): FilesViewState | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as { expanded?: unknown; selected?: unknown; scroll?: unknown };
  if (!Array.isArray(raw.expanded)) return null;
  return {
    expanded: raw.expanded.filter((path): path is string => typeof path === "string"),
    ...(typeof raw.selected === "string" ? { selected: raw.selected } : {}),
    scroll: typeof raw.scroll === "number" && Number.isFinite(raw.scroll) ? Math.max(0, raw.scroll) : 0,
  };
}

export interface Listing {
  entries: FileEntry[];
  /** The folder has more children than the page was sent. */
  truncated: boolean;
}
