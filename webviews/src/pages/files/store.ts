// The Files page's state owner: the root folder, each listed folder's children, which folders are
// expanded and which row is selected. Folders list on first expand and again on refresh. React reads
// it through `useSyncExternalStore`.
import { isPageError, type PageClient } from "../shared/pageClient";
import { CLIPBOARD_WRITE, FilesOps, type FileEntry, type Listing, type RootInfo } from "./types";

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
  rows: Row[];
  folders: ReadonlyMap<string, FolderState>;
  selected?: string;
}

export const joinPath = (folder: string, name: string) => (folder ? `${folder}/${name}` : name);
export const parentPath = (path: string) => path.slice(0, Math.max(0, path.lastIndexOf("/")));

export class FilesStore {
  private root?: RootInfo;
  private failed?: string;
  private folders = new Map<string, FolderState>();
  private expanded = new Set<string>();
  private selected?: string;
  private snapshot: FilesSnapshot = { rows: [], folders: this.folders };
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
    if (!this.client) return this.fail("cmux.files.unavailable");
    try {
      this.root = await this.client.call<RootInfo>(FilesOps.root, {});
    } catch (error) {
      return this.fail(isPageError(error) ? error.message : String(error));
    }
    this.emit();
    await this.list("");
    const first = this.rows()[0];
    if (first && this.selected === undefined) this.select(first.path);
  }

  /** Lists `path` again, and every expanded folder under it. */
  async refresh(): Promise<void> {
    const folders = ["", ...[...this.expanded].sort()];
    await Promise.all(folders.map((folder) => this.list(folder)));
  }

  select(path: string | undefined): void {
    if (this.selected === path) return;
    this.selected = path;
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
      this.setFolder(parentPath(path), { failed: isPageError(error) ? error.message : String(error) });
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
    this.setFolder(path, { loading: true, failed: undefined });
    try {
      const listing = await this.client.call<Listing>(FilesOps.list, { path });
      this.setFolder(path, { entries: listing.entries, truncated: listing.truncated, loading: false });
    } catch (error) {
      const failed = isPageError(error) ? error.message : String(error);
      this.setFolder(path, { loading: false, failed });
    }
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
      rows: this.rows(),
      folders: this.folders,
      selected: this.selected,
    };
    for (const listener of this.listeners) listener();
  }
}
