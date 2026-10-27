// The Files page's state owner: the root folder, each listed folder's children, which folders are
// expanded and which row is selected. Folders list on first expand and again on refresh. React reads
// it through `useSyncExternalStore`.
import { isPageError, type PageClient } from "../shared/pageClient";
import { restoredPageInputs } from "../shared/pageState";
import {
  CLIPBOARD_WRITE,
  FilesOps,
  filesViewStateOf,
  type FileEntry,
  type FilesViewState,
  type Listing,
  type RootInfo,
} from "./types";

export interface FolderState {
  entries?: FileEntry[];
  truncated?: boolean;
  loading: boolean;
  /** Why the folder did not list, in plain words. */
  failed?: string;
}

/** One visible row: an entry at `depth` (0 for the root's children). */
export interface Row {
  path: string;
  name: string;
  kind: FileEntry["kind"];
  depth: number;
  expanded: boolean;
}

export interface FilesSnapshot {
  root?: RootInfo;
  /** Why the page has no folder (no tab folder, not a repository, an old session host). */
  failed?: string;
  /** The page has no host to ask; the page says so in its own words. */
  unavailable?: boolean;
  /** Why the last file did not open; the next selection clears it. */
  notice?: string;
  rows: Row[];
  folders: ReadonlyMap<string, FolderState>;
  expanded: ReadonlySet<string>;
  selected?: string;
}

/** The page name its saved state carries (pageState.ts). */
export const FILES_PAGE = "files";

/** What the page keeps across a discard: the open folders and the selected row (the scroll is the page state's). */
export type FilesInputs = Omit<FilesViewState, "scroll">;

export const joinPath = (folder: string, name: string) => (folder ? `${folder}/${name}` : name);
export const parentPath = (path: string) => path.slice(0, Math.max(0, path.lastIndexOf("/")));

export class FilesStore {
  private root?: RootInfo;
  private failed?: string;
  private unavailable = false;
  private notice?: string;
  /** The latest `list` request per folder: an older reply that lands after a newer one is dropped.
   * Ids count up across the page, so a folder listed again after it was forgotten never reuses one. */
  private requests = new Map<string, number>();
  private lastRequest = 0;
  private folders = new Map<string, FolderState>();
  private expanded = new Set<string>();
  private selected?: string;
  private restoredScroll: number | null = null;
  private snapshot: FilesSnapshot = { rows: [], folders: this.folders, expanded: new Set() };
  private listeners = new Set<() => void>();

  constructor(
    private readonly client: PageClient | null,
    private readonly writeClipboard?: (text: string) => Promise<void>,
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  async start(): Promise<void> {
    if (!this.client) {
      this.unavailable = true;
      return this.emit();
    }
    try {
      this.root = await this.client.call<RootInfo>(FilesOps.root, {});
    } catch (error) {
      return this.fail(isPageError(error) ? error.message : String(error));
    }
    // A discarded page's tree comes back: its open folders list again, its row stays selected. The
    // host's answer to its discard-time ask wins over what the page saved when it hid.
    const saved =
      filesViewStateOf(this.root.viewState) ?? filesViewStateOf(restoredPageInputs(this.client, FILES_PAGE));
    if (saved) {
      for (const path of saved.expanded) this.expanded.add(path);
      this.selected = saved.selected;
      this.restoredScroll = saved.scroll;
    }
    this.emit();
    await this.refresh();
    const first = this.rows()[0];
    if (first && this.selected === undefined) this.select(first.path);
  }

  /** `cmux.files.viewState`: the open folders and selected row, with the tree scrolled to `scroll`. */
  viewState(scroll: number): FilesViewState {
    return {
      expanded: [...this.expanded].sort(),
      ...(this.selected !== undefined ? { selected: this.selected } : {}),
      scroll,
    };
  }

  /** What the page keeps when it hides (pageState.ts `keep`); `filesViewStateOf` reads it back. */
  pageInputs(): FilesInputs {
    const { expanded, selected } = this.viewState(0);
    return selected === undefined ? { expanded } : { expanded, selected };
  }

  /** The scroll a discarded page of this tab was at, once; null when there is none. */
  takeRestoredScroll(): number | null {
    const scroll = this.restoredScroll;
    this.restoredScroll = null;
    return scroll;
  }

  /** Lists `path` again, and every expanded folder under it. */
  async refresh(): Promise<void> {
    const folders = ["", ...[...this.expanded].sort()];
    await Promise.all(folders.map((folder) => this.list(folder)));
  }

  select(path: string | undefined): void {
    if (this.selected === path) return;
    this.selected = path;
    this.notice = undefined;
    this.emit();
  }

  toggle(path: string): void {
    if (this.expanded.has(path)) this.collapse(path);
    else this.expand(path);
  }

  expand(path: string): void {
    if (this.expanded.has(path)) return;
    this.expanded.add(path);
    this.emit();
    if (!this.folders.get(path)?.entries) void this.list(path);
  }

  collapse(path: string): void {
    if (!this.expanded.delete(path)) return;
    // The selection never hides inside a collapsed folder.
    if (this.selected?.startsWith(`${path}/`)) this.selected = path;
    this.emit();
  }

  async open(path: string): Promise<void> {
    try {
      await this.client?.call(FilesOps.open, { path });
    } catch (error) {
      this.notice = isPageError(error) ? error.message : String(error);
      this.emit();
    }
  }

  async copy(text: string): Promise<void> {
    try {
      if (!this.writeClipboard) throw new Error("no page clipboard");
      await this.writeClipboard(text);
    } catch {
      await this.client?.call(CLIPBOARD_WRITE, { text }).catch(() => {});
    }
  }

  absolutePath(path: string): string | undefined {
    return this.root ? (path ? `${this.root.folder}/${path}` : this.root.folder) : undefined;
  }

  private async list(path: string): Promise<void> {
    if (!this.client) return;
    const request = ++this.lastRequest;
    this.requests.set(path, request);
    this.setFolder(path, { loading: true, failed: undefined });
    try {
      const listing = await this.client.call<Listing>(FilesOps.list, { path });
      if (this.requests.get(path) !== request) return;
      this.forgetGone(path, listing.entries);
      this.setFolder(path, { entries: listing.entries, truncated: listing.truncated, loading: false });
    } catch (error) {
      if (this.requests.get(path) !== request) return;
      const failed = isPageError(error) ? error.message : String(error);
      this.setFolder(path, { loading: false, failed });
    }
  }

  /** Drops what `folder` no longer holds as a folder: its expansion, listing and anything under it. */
  private forgetGone(folder: string, entries: FileEntry[]): void {
    const kept = new Set(
      entries.filter((entry) => entry.kind === "directory").map((entry) => joinPath(folder, entry.name)),
    );
    const known = new Set([...this.expanded, ...this.folders.keys()]);
    const gone = [...known].filter((path) => path !== folder && parentPath(path) === folder && !kept.has(path));
    if (gone.length === 0) return;
    const inside = (path: string) => gone.some((top) => path === top || path.startsWith(`${top}/`));
    this.folders = new Map(this.folders);
    for (const path of [...known].filter(inside)) {
      this.expanded.delete(path);
      this.folders.delete(path);
      this.requests.delete(path);
    }
    if (this.selected !== undefined && gone.some((top) => this.selected!.startsWith(`${top}/`)))
      this.selected = folder || undefined;
  }

  private setFolder(path: string, patch: Partial<FolderState>): void {
    const state = this.folders.get(path) ?? { loading: false };
    this.folders = new Map(this.folders).set(path, { ...state, ...patch });
    this.emit();
  }

  private fail(message: string): void {
    this.failed = message;
    this.emit();
  }

  /** The visible rows, depth first, in the session host's order (folders first, then by name). */
  private rows(): Row[] {
    const rows: Row[] = [];
    const walk = (folder: string, depth: number) => {
      for (const entry of this.folders.get(folder)?.entries ?? []) {
        const path = joinPath(folder, entry.name);
        const expanded = entry.kind === "directory" && this.expanded.has(path);
        rows.push({ path, name: entry.name, kind: entry.kind, depth, expanded });
        if (expanded) walk(path, depth + 1);
      }
    };
    walk("", 0);
    return rows;
  }

  private emit(): void {
    this.snapshot = {
      root: this.root,
      failed: this.failed,
      unavailable: this.unavailable,
      notice: this.notice,
      rows: this.rows(),
      folders: this.folders,
      expanded: new Set(this.expanded),
      selected: this.selected,
    };
    for (const listener of this.listeners) listener();
  }
}
