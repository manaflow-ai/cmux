// The Artifacts page's state owner: the synced tree and the chosen file. React reads it through
// `useSyncExternalStore`; a reply for a file the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
import { ArtifactsOps, type ArtifactFile, type ArtifactsTree } from "./types";

/** Folders read for one tree: the platform lists one level per read. */
export const MAX_FOLDERS = 200;
/** Folder reads in flight at once. */
const FOLDER_READS = 4;

/** What went wrong, by the app's error code; the page words it. */
export interface ArtifactsFailure {
  code: string;
  message?: string;
}

export interface ArtifactsSnapshot {
  /** `unavailable`: no host to ask. `empty`: nothing saved yet. */
  status: "idle" | "loading" | "ready" | "empty" | "failed" | "unavailable";
  failure?: ArtifactsFailure;
  /** Every file path in the tree, sorted. */
  paths: string[];
  /** The tree had more folders than ``MAX_FOLDERS``; the rest are not listed. */
  truncated: boolean;
  headSha?: string;
  selected?: string;
  file?: ArtifactFile;
  fileLoading: boolean;
  fileFailure?: ArtifactsFailure;
}

const INITIAL: ArtifactsSnapshot = { status: "idle", paths: [], truncated: false, fileLoading: false };

export class ArtifactsStore {
  private snapshot: ArtifactsSnapshot = INITIAL;
  private listeners = new Set<() => void>();
  private treeRequest = 0;
  private fileRequest = 0;
  /** The head the chosen file was last read at; a refresh at another head reads it again. */
  private fileHead?: string;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = (): ArtifactsSnapshot => this.snapshot;

  /**
   * Reads the tree, then opens its first file unless one is already chosen. When the head moved
   * since the last read, the chosen file reads again, so a revision saved meanwhile shows.
   */
  async start(): Promise<void> {
    if (!this.client) return this.set({ ...INITIAL, status: "unavailable" });
    const request = ++this.treeRequest;
    // A refresh keeps the tree on screen until the new one arrives.
    if (this.snapshot.status !== "ready") this.set({ status: "loading", failure: undefined });
    try {
      const { paths, sha, truncated } = await this.readTree(this.client);
      if (request !== this.treeRequest) return;
      this.set({ status: paths.length ? "ready" : "empty", paths, headSha: sha, truncated });
      const selected = this.snapshot.selected;
      if (selected && paths.includes(selected)) {
        if (this.fileHead !== sha) await this.select(selected, true);
      } else if (paths[0]) await this.select(paths[0]);
    } catch (error) {
      if (request !== this.treeRequest) return;
      const failure = failureOf(error);
      // A refresh that fails keeps the tree it had on screen; the next one tries again. Signed out
      // (or nothing saved any more) drops it, so another account's tree never stays up.
      const keep = !["cmux.artifacts.not_found", "cmux.artifacts.signed_out"].includes(failure.code);
      if (this.snapshot.status === "ready" && keep) return;
      this.set({ status: failure.code === "cmux.artifacts.not_found" ? "empty" : "failed", failure, paths: [] });
    }
  }

  /**
   * Opens `path` at the tree's head. `reload` reads the chosen file again and keeps what is shown
   * until the new read arrives.
   */
  async select(path: string, reload = false): Promise<void> {
    const client = this.client;
    // The chosen file again only to retry a failed read.
    if (!client || (path === this.snapshot.selected && !reload && !this.snapshot.fileFailure)) return;
    const request = ++this.fileRequest;
    // Read at the tree's commit, so the preview matches the tree even if a save lands meanwhile.
    const head = this.snapshot.headSha;
    if (!reload) this.set({ selected: path, file: undefined, fileLoading: true, fileFailure: undefined });
    try {
      const file = await client.call<ArtifactFile>(ArtifactsOps.file, head ? { path, ref: head } : { path });
      if (request !== this.fileRequest) return;
      this.set({ file, fileLoading: false, fileFailure: undefined });
      this.fileHead = head;
    } catch (error) {
      if (request === this.fileRequest) this.set({ fileLoading: false, fileFailure: failureOf(error) });
    }
  }

  /**
   * Every file path under the root, one level per read: the root first, then up to
   * ``FOLDER_READS`` folders at once, at most ``MAX_FOLDERS`` folders in all.
   */
  private async readTree(client: PageClient): Promise<{ paths: string[]; sha?: string; truncated: boolean }> {
    const files: string[] = [];
    const queue: string[] = [];
    let sha: string | undefined;
    // Folders read or waiting, the root included.
    let listed = 1;
    let truncated = false;
    const read = async (folder: string): Promise<void> => {
      // Folders read at the root's commit, so a save landing meanwhile cannot mix two trees.
      const tree = await client.call<ArtifactsTree>(ArtifactsOps.tree, folder ? { path: folder, ref: sha } : {});
      sha ??= tree.sha;
      for (const entry of tree.entries) {
        if (entry.type === "blob") files.push(entry.path);
        else if (listed < MAX_FOLDERS) {
          listed += 1;
          queue.push(entry.path);
        } else truncated = true;
      }
    };
    await read("");
    while (queue.length) await Promise.all(queue.splice(0, FOLDER_READS).map(read));
    return { paths: files.sort(), sha, truncated };
  }

  private set(patch: Partial<ArtifactsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

/** The file's text, or undefined when it has none to show (too large, or not text). */
export function textOf(file: ArtifactFile): string | undefined {
  if (file.tooLarge || file.content === undefined || file.encoding === "base64") return undefined;
  return file.content;
}

function failureOf(error: unknown): ArtifactsFailure {
  return isPageError(error) ? { code: error.code, message: error.message } : { code: "cmux.artifacts.failed" };
}
