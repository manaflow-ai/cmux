// The Artifacts page's state owner: the synced tree, the chosen file, its history and the chosen
// revision's change. React reads it through `useSyncExternalStore`; a reply for a file or revision
// the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  ArtifactsOps,
  type ArtifactCommit,
  type ArtifactFile,
  type ArtifactHistory,
  type ArtifactsTree,
} from "./types";

/** Folders read for one tree: the platform lists one level per read. */
export const MAX_FOLDERS = 200;
/** Folder reads in flight at once. */
const FOLDER_READS = 4;
/** Revisions shown for a file. */
export const HISTORY_LIMIT = 50;

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
  history: ArtifactCommit[];
  selectedCommit?: string;
  /** The chosen revision against its parent; `before` is absent for the file's first revision. */
  diff?: { sha: string; before?: string; after: string };
}

const INITIAL: ArtifactsSnapshot = { status: "idle", paths: [], truncated: false, fileLoading: false, history: [] };

export class ArtifactsStore {
  private snapshot: ArtifactsSnapshot = INITIAL;
  private listeners = new Set<() => void>();
  private treeRequest = 0;
  private fileRequest = 0;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = (): ArtifactsSnapshot => this.snapshot;

  /** Reads the tree, then opens its first file unless one is already chosen. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ ...INITIAL, status: "unavailable" });
    const request = ++this.treeRequest;
    // A refresh keeps the tree on screen until the new one arrives.
    if (this.snapshot.status !== "ready") this.set({ status: "loading", failure: undefined });
    try {
      const { paths, sha, truncated } = await this.readTree(this.client);
      if (request !== this.treeRequest) return;
      this.set({ status: paths.length ? "ready" : "empty", paths, headSha: sha, truncated });
      const keep = this.snapshot.selected && paths.includes(this.snapshot.selected);
      if (!keep && paths[0]) await this.select(paths[0]);
    } catch (error) {
      if (request !== this.treeRequest) return;
      const failure = failureOf(error);
      this.set({ status: failure.code === "cmux.artifacts.not_found" ? "empty" : "failed", failure, paths: [] });
    }
  }

  /** Opens `path`: its content at the head and its history, with the newest revision's change. */
  async select(path: string): Promise<void> {
    const client = this.client;
    if (!client || path === this.snapshot.selected) return;
    const request = ++this.fileRequest;
    this.set({
      selected: path,
      file: undefined,
      fileLoading: true,
      fileFailure: undefined,
      history: [],
      selectedCommit: undefined,
      diff: undefined,
    });
    try {
      const [file, history] = await Promise.all([
        client.call<ArtifactFile>(ArtifactsOps.file, { path }),
        client.call<ArtifactHistory>(ArtifactsOps.history, { path, limit: HISTORY_LIMIT }),
      ]);
      if (request !== this.fileRequest) return;
      this.set({ file, history: history.commits, fileLoading: false });
      const newest = history.commits[0];
      if (newest) await this.showCommit(newest, request, file);
    } catch (error) {
      if (request === this.fileRequest) this.set({ fileLoading: false, fileFailure: failureOf(error) });
    }
  }

  /** Shows `commit`'s change to the chosen file. */
  async selectCommit(commit: ArtifactCommit): Promise<void> {
    if (!this.client || !this.snapshot.selected || commit.sha === this.snapshot.selectedCommit) return;
    await this.showCommit(commit, ++this.fileRequest);
  }

  private async showCommit(commit: ArtifactCommit, request: number, head?: ArtifactFile): Promise<void> {
    const client = this.client;
    const path = this.snapshot.selected;
    if (!client || !path) return;
    this.set({ selectedCommit: commit.sha, diff: undefined, fileFailure: undefined });
    const text = async (ref: string) => textOf(await client.call<ArtifactFile>(ArtifactsOps.file, { path, ref }));
    try {
      const parent = commit.parents[0];
      const [after, before] = await Promise.all([
        head && head.commit === commit.sha ? textOf(head) : text(commit.sha),
        // A parent where the file did not exist yet answers not found: the file was added.
        parent
          ? text(parent).catch((error: unknown) =>
              failureOf(error).code === "cmux.artifacts.not_found" ? undefined : Promise.reject(error),
            )
          : undefined,
      ]);
      if (request === this.fileRequest) this.set({ diff: { sha: commit.sha, before, after: after ?? "" } });
    } catch (error) {
      if (request === this.fileRequest) this.set({ fileFailure: failureOf(error) });
    }
  }

  /** Every file path under the root, one level per read, at most ``MAX_FOLDERS`` folders. */
  private async readTree(client: PageClient): Promise<{ paths: string[]; sha?: string; truncated: boolean }> {
    const files: string[] = [];
    const queue = [""];
    let sha: string | undefined;
    let read = 0;
    let truncated = false;
    const next = async (): Promise<void> => {
      for (let folder = queue.shift(); folder !== undefined; folder = queue.shift()) {
        read += 1;
        const tree = await client.call<ArtifactsTree>(ArtifactsOps.tree, folder ? { path: folder } : {});
        sha ??= tree.sha;
        for (const entry of tree.entries) {
          if (entry.type === "blob") files.push(entry.path);
          else if (read + queue.length < MAX_FOLDERS) queue.push(entry.path);
          else truncated = true;
        }
      }
    };
    // The root first, so its folders can fan out.
    await next();
    while (queue.length) await Promise.all(Array.from({ length: Math.min(FOLDER_READS, queue.length) }, next));
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
