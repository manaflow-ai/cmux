import { isPageError, type PageClient } from "../../shared/pageClient";
import { ArtifactsOps, type ArtifactCommit, type ArtifactFile, type ArtifactsTree } from "./types";
export type ArtifactsSnapshot = {
  tree?: ArtifactsTree;
  selected?: string;
  file?: ArtifactFile;
  history: ArtifactCommit[];
  selectedCommit?: string;
  diff?: { before?: ArtifactFile; after: ArtifactFile };
  loading: boolean;
  error?: string;
};
export class ArtifactsStore {
  private snapshot: ArtifactsSnapshot = { history: [], loading: true };
  private listeners = new Set<() => void>();
  private request = 0;
  constructor(private readonly client: PageClient | null) { if (!client) this.snapshot = { history: [], loading: false, error: "Artifacts are unavailable until the host is connected." }; }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => void this.listeners.delete(listener); };
  getSnapshot = () => this.snapshot;
  async start() { if (!this.client) return; await this.loadTree(); }
  async select(path: string) {
    if (!this.client || path === this.snapshot.selected) return;
    const request = ++this.request; this.set({ selected: path, loading: true, error: undefined });
    try {
      const [file, history] = await Promise.all([
        this.client.call<ArtifactFile>(ArtifactsOps.file, { path, ref: "main" }),
        this.client.call<{ commits: ArtifactCommit[] }>(ArtifactsOps.history, { path, ref: "main", limit: 50 }),
      ]);
      if (request !== this.request) return;
      const selectedCommit = history.commits[0];
      const diff = selectedCommit ? await this.fetchDiff(path, selectedCommit, file, request) : undefined;
      if (request !== this.request) return;
      this.set({ file, history: history.commits, selectedCommit: selectedCommit?.sha, diff, loading: false });
    } catch (error) { if (request === this.request) this.set({ loading: false, error: isPageError(error) ? error.message : String(error) }); }
  }
  async selectCommit(commit: ArtifactCommit) {
    const path = this.snapshot.selected;
    if (!this.client || !path || commit.sha === this.snapshot.selectedCommit) return;
    const request = ++this.request;
    this.set({ selectedCommit: commit.sha, loading: true, error: undefined });
    try {
      const diff = await this.fetchDiff(path, commit, undefined, request);
      if (request === this.request) this.set({ diff, loading: false });
    } catch (error) { if (request === this.request) this.set({ loading: false, error: isPageError(error) ? error.message : String(error) }); }
  }
  async loadTree() {
    if (!this.client) return;
    this.set({ loading: true, error: undefined });
    try {
      const tree = await this.client.call<ArtifactsTree>(ArtifactsOps.tree, { ref: "main", path: "" });
      this.set({ tree, loading: false });
      const first = tree.entries.find((entry) => entry.type === "blob");
      if (first) await this.select(first.path);
    } catch (error) { this.set({ loading: false, error: isPageError(error) ? error.message : String(error) }); }
  }
  private async fetchDiff(path: string, commit: ArtifactCommit, current: ArtifactFile | undefined, request: number) {
    if (!this.client) return undefined;
    const after = current?.commit === commit.sha
      ? current
      : await this.client.call<ArtifactFile>(ArtifactsOps.file, { path, ref: commit.sha });
    if (request !== this.request) return undefined;
    const before = commit.parents[0]
      ? await this.client.call<ArtifactFile>(ArtifactsOps.file, { path, ref: commit.parents[0] })
      : undefined;
    return { before, after };
  }
  private set(patch: Partial<ArtifactsSnapshot>) { this.snapshot = { ...this.snapshot, ...patch }; for (const listener of this.listeners) listener(); }
}
