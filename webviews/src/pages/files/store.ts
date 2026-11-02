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
  /** The page has no host to ask; the page says so in its own words. */
  unavailable?: boolean;
  /** Why the last file did not open; the next selection clears it. */
  notice?: string;
  rows: Row[];
  folders: ReadonlyMap<string, FolderState>;
  expanded: ReadonlySet<string>;
  selected?: string;
}

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
  /** Changes whenever navigation changes the context for an in-flight open. */
  private selectionEpoch = 0;
  /** Every open gets a unique token, including retries of the same path. */
  private openAttempt = 0;
  /** The latest copy: an older one's late failure is not the notice for what is on screen now. */
  private copyAttempt = 0;
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
    this.setSelection(path);
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
    if (this.selected?.startsWith(`${path}/`)) this.setSelection(path);
    this.emit();
  }

  async open(path: string): Promise<void> {
    const epoch = this.selectionEpoch;
    const attempt = ++this.openAttempt;
    this.notice = undefined;
    this.emit();
    try {
      await this.client?.call(FilesOps.open, { path });
    } catch (error) {
      if (this.selectionEpoch !== epoch || this.openAttempt !== attempt) return;
      this.notice = isPageError(error) ? error.message : String(error);
      this.emit();
    }
  }

  async copy(text: string): Promise<void> {
    const attempt = ++this.copyAttempt;
    const epoch = this.selectionEpoch;
    const opened = this.openAttempt;
    try {
      if (!this.writeClipboard) throw new Error("no page clipboard");
      await this.writeClipboard(text);
    } catch {
      // The page's clipboard refused (or is not there): the host writes it. When it cannot either,
      // the person is told, not left to paste what was never copied.
      try {
        await this.client?.call(CLIPBOARD_WRITE, { text });
      } catch (error) {
        // A newer copy, another selection or an open began meanwhile: this failure is stale.
        if (attempt !== this.copyAttempt || epoch !== this.selectionEpoch || opened !== this.openAttempt) return;
        this.notice = isPageError(error) ? error.message : String(error);
        this.emit();
      }
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
      // A truncated listing is only a partial view; entries omitted from it may still exist.
      if (!listing.truncated) this.forgetGone(path, listing.entries);
      this.setFolder(path, { entries: listing.entries, truncated: listing.truncated, loading: false });
    } catch (error) {
      if (this.requests.get(path) !== request) return;
      const failed = isPageError(error) ? error.message : String(error);
      this.setFolder(path, { loading: false, failed });
    }
  }

  /** Drops what `folder` no longer holds as a folder: its expansion, listing and anything under it. */
  private forgetGone(folder: string, entries: FileEntry[]): void {
    const present = new Set(entries.map((entry) => joinPath(folder, entry.name)));
    const kept = new Set(
      entries.filter((entry) => entry.kind === "directory").map((entry) => joinPath(folder, entry.name)),
    );
    const known = new Set([...this.expanded, ...this.folders.keys()]);
    const gone = [...known].filter((path) => path !== folder && parentPath(path) === folder && !kept.has(path));
    // A selected file has no folder state, so a deleted one is reconciled here as well.
    const selectedGone =
      this.selected !== undefined && parentPath(this.selected) === folder && !present.has(this.selected);
    if (gone.length === 0 && !selectedGone) return;
    const inside = (path: string) => gone.some((top) => path === top || path.startsWith(`${top}/`));
    this.folders = new Map(this.folders);
    for (const path of [...known].filter(inside)) {
      this.expanded.delete(path);
      this.folders.delete(path);
      this.requests.delete(path);
    }
    if (this.selected !== undefined && (selectedGone || gone.some((top) => this.selected!.startsWith(`${top}/`))))
      this.setSelection(folder || undefined);
  }

  private setSelection(path: string | undefined): void {
    if (this.selected === path) return;
    this.selected = path;
    this.selectionEpoch++;
    this.notice = undefined;
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
