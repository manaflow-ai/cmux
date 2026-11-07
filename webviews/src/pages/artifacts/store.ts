// The Artifacts page's state owner: the synced tree, the chosen file, its history and the chosen
// revision's change. React reads it through `useSyncExternalStore`; a reply for a file or revision
// the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  ACTION_RUN,
  ArtifactsActions,
  ArtifactsOps,
  SIGNED_OUT,
  type ArtifactCommit,
  type ArtifactFile,
  type ArtifactHistory,
  type ArtifactsTree,
} from "./types";

/** Folders read for one tree: the platform lists one level per read. */
export const MAX_FOLDERS = 200;
/** Folder reads in flight at once. */
const FOLDER_READS = 4;
const AUTH_WATCH = "cmux.cloud.auth.watch";
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
  /** Why the chosen file's history could not be read; its preview still shows. */
  historyFailure?: ArtifactsFailure;
  selectedCommit?: string;
  /**
   * The chosen revision against its parent; `before` is absent for the file's first revision.
   * `unavailable`: either side has no text to compare (binary or too large), so no change shows.
   */
  diff?: { sha: string; before?: string; after: string; unavailable?: boolean };
}

const INITIAL: ArtifactsSnapshot = { status: "idle", paths: [], truncated: false, fileLoading: false, history: [] };

export class ArtifactsStore {
  private snapshot: ArtifactsSnapshot = INITIAL;
  private listeners = new Set<() => void>();
  private treeRequest = 0;
  private fileRequest = 0;
  private watchingAuth = false;
  private unwatchAuth?: () => void;
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
    await this.watchAuth();
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
      const keep = !["cmux.artifacts.not_found", SIGNED_OUT].includes(failure.code);
      if (this.snapshot.status === "ready" && keep) return;
      this.fileRequest += 1;
      this.fileHead = undefined;
      this.set({
        status: failure.code === "cmux.artifacts.not_found" ? "empty" : "failed",
        failure,
        paths: [],
        truncated: false,
        headSha: undefined,
        selected: undefined,
        file: undefined,
        fileLoading: false,
        fileFailure: undefined,
        history: [],
        historyFailure: undefined,
        selectedCommit: undefined,
        diff: undefined,
      });
    }
  }

  /** Runs the app's Sign In. The auth watch reads the tree again once the person is signed in. */
  async signIn(): Promise<void> {
    try {
      await this.client?.call(ACTION_RUN, { action: ArtifactsActions.signIn });
    } catch {
      // The app shows its own error for a sign-in that did not start; the page stays as it is.
    }
  }

  /** Drop the old account's tree and preview as soon as the host reports an auth change. */
  private async watchAuth(): Promise<void> {
    if (!this.client || this.unwatchAuth || this.watchingAuth) return;
    this.watchingAuth = true;
    try {
      const unwatch = await this.client.subscribe(AUTH_WATCH, () => {
        this.treeRequest += 1;
        this.fileRequest += 1;
        this.fileHead = undefined;
        this.set({
          status: "loading",
          failure: undefined,
          paths: [],
          truncated: false,
          headSha: undefined,
          selected: undefined,
          file: undefined,
          fileLoading: false,
          fileFailure: undefined,
          history: [],
          historyFailure: undefined,
          selectedCommit: undefined,
          diff: undefined,
        });
        void this.start();
      });
      this.unwatchAuth = unwatch;
    } catch {
      // Older hosts have no auth stream; visibility refresh still remains available.
    } finally {
      this.watchingAuth = false;
    }
  }

  /**
   * Opens `path`: its content at the head and its history, with the newest revision's change.
   * `reload` reads the chosen file again and keeps what is shown until the new reads arrive.
   */
  async select(path: string, reload = false): Promise<void> {
    const client = this.client;
    // The chosen file again only to retry a failed read.
    if (!client || (path === this.snapshot.selected && !reload && !this.snapshot.fileFailure)) return;
    const request = ++this.fileRequest;
    // Read at the tree's commit, so the preview matches the tree even if a save lands meanwhile.
    const head = this.snapshot.headSha;
    if (!reload)
      this.set({
        selected: path,
        file: undefined,
        fileLoading: true,
        fileFailure: undefined,
        history: [],
        historyFailure: undefined,
        selectedCommit: undefined,
        diff: undefined,
      });
    // The file and its history are read at once but answer on their own: a history that fails
    // to read never hides the file's preview.
    const historyRead = client
      .call<ArtifactHistory>(
        ArtifactsOps.history,
        head ? { path, ref: head, limit: HISTORY_LIMIT } : { path, limit: HISTORY_LIMIT },
      )
      .then(
        (history) => ({ history }),
        (error: unknown) => ({ failure: failureOf(error) }),
      );
    let file: ArtifactFile;
    try {
      file = await client.call<ArtifactFile>(ArtifactsOps.file, head ? { path, ref: head } : { path });
    } catch (error) {
      if (request === this.fileRequest) this.set({ fileLoading: false, fileFailure: failureOf(error) });
      return;
    }
    if (request !== this.fileRequest) return;
    this.set({ file, fileLoading: false, fileFailure: undefined });
    const read = await historyRead;
    if (request !== this.fileRequest) return;
    if ("failure" in read) {
      // Not read at this head yet: a refresh tries the history again.
      this.set({ historyFailure: read.failure });
      return;
    }
    this.set({ history: read.history.commits, historyFailure: undefined });
    const newest = read.history.commits[0];
    // Read at this head only once its newest change shows too; otherwise a refresh tries again.
    if (!newest || (await this.showCommit(newest, request, file))) this.fileHead = head;
  }

  /** Shows `commit`'s change to the chosen file; the chosen revision again only to retry a failed read. */
  async selectCommit(commit: ArtifactCommit): Promise<void> {
    if (!this.client || !this.snapshot.selected) return;
    if (commit.sha === this.snapshot.selectedCommit && this.snapshot.diff?.sha === commit.sha) return;
    await this.showCommit(commit, ++this.fileRequest);
  }

  /** Whether `commit`'s change now shows (false: it failed, or the person moved on). */
  private async showCommit(commit: ArtifactCommit, request: number, head?: ArtifactFile): Promise<boolean> {
    const client = this.client;
    const path = this.snapshot.selected;
    if (!client || !path) return false;
    // Reading the same revision again (a refresh) keeps its change on screen meanwhile.
    const same = this.snapshot.diff?.sha === commit.sha;
    this.set({ selectedCommit: commit.sha, fileFailure: undefined, ...(same ? {} : { diff: undefined }) });
    const read = (ref: string) => client.call<ArtifactFile>(ArtifactsOps.file, { path, ref });
    try {
      const parent = commit.parents[0];
      const [afterFile, beforeFile] = await Promise.all([
        head && head.commit === commit.sha ? head : read(commit.sha),
        // A parent where the file did not exist yet answers not found: the file was added.
        parent
          ? read(parent).catch((error: unknown) =>
              failureOf(error).code === "cmux.artifacts.not_found" ? undefined : Promise.reject(error),
            )
          : undefined,
      ]);
      if (request !== this.fileRequest) return false;
      const after = textOf(afterFile);
      const before = beforeFile ? textOf(beforeFile) : undefined;
      // A binary or too-large side has no text: say so rather than diff it as empty.
      const unavailable = after === undefined || (beforeFile !== undefined && before === undefined);
      this.set({
        diff: unavailable ? { sha: commit.sha, after: "", unavailable } : { sha: commit.sha, before, after },
      });
      return true;
    } catch (error) {
      if (request === this.fileRequest) this.set({ fileFailure: failureOf(error) });
      return false;
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
