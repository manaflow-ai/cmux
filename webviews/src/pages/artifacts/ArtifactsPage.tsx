import { useEffect, useMemo, useSyncExternalStore } from "react";
import { FileDiff } from "@pierre/diffs/react";
import { getSingularPatch } from "@pierre/diffs";
import { FileTree, useFileTree } from "@pierre/trees/react";
import type { Strings } from "../shared/i18n";
import type { ArtifactsStore } from "./store";
import type { ArtifactCommit } from "./types";
import "./styles.css";

function safeDocument(content: string): string {
  const csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; navigate-to 'none'";
  const meta = `<meta http-equiv="Content-Security-Policy" content="${csp}">`;
  return /<head\b/i.test(content) ? content.replace(/<head(\b[^>]*)>/i, (tag) => `${tag}${meta}`) : `${meta}${content}`;
}
function patchFor(path: string, before: string, after: string) {
  const oldLines = before.split("\n");
  const newLines = after.split("\n");
  return getSingularPatch([
    `--- a/${path}`,
    `+++ b/${path}`,
    `@@ -1,${oldLines.length} +1,${newLines.length} @@`,
    ...oldLines.map((line) => `-${line}`),
    ...newLines.map((line) => `+${line}`),
    "",
  ].join("\n"));
}
function kind(path: string): "html" | "text" | "json" { return path.endsWith(".html") ? "html" : path.endsWith(".json") ? "json" : "text"; }

export function ArtifactsPage({ store, strings: _strings }: { store: ArtifactsStore; strings?: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const entries = snapshot.tree?.entries ?? [];
  const paths = useMemo(() => entries.filter((entry) => entry.type === "blob").map((entry) => entry.path), [entries]);
  const { model } = useFileTree({ paths, initialExpansion: "open", onSelectionChange: (selected) => { const path = selected.at(-1); if (path) void store.select(path); } });
  useEffect(() => { void store.start(); }, [store]);
  if (snapshot.error && !snapshot.tree) return <p className="artifacts-message" role="alert">{snapshot.error}</p>;
  const fileKind = snapshot.file ? kind(snapshot.file.path) : "text";
  return (
    <div className="artifacts-page">
      <aside className="artifacts-tree" aria-label="Artifacts files">
        <header className="artifacts-tree-header"><strong>Artifacts</strong><span>{snapshot.tree?.sha ? `main · ${snapshot.tree.sha.slice(0, 7)}` : "Loading"}</span></header>
        <FileTree model={model} id="artifacts-file-tree" style={{ height: "100%" }} />
      </aside>
      <main className="artifacts-main">
        <header className="artifacts-file-header"><strong>{snapshot.file?.path ?? "Select a file"}</strong>{snapshot.file?.commit ? <span>commit {snapshot.file.commit.slice(0, 7)}</span> : null}</header>
        {snapshot.error ? <p className="artifacts-inline-error" role="alert">{snapshot.error}</p> : null}
        {snapshot.loading && !snapshot.file ? <p className="artifacts-message">Loading artifacts…</p> : snapshot.file && fileKind === "html" ? <iframe className="artifacts-frame" title="Artifact preview" sandbox="allow-scripts" srcDoc={safeDocument(snapshot.file.content)} /> : snapshot.file ? <pre className="artifacts-content">{snapshot.file.content}</pre> : <p className="artifacts-message">Choose a file from the tree.</p>}
        <section className="artifacts-history" aria-label="Artifact history">
          <h2>History</h2>
          {snapshot.history.length === 0 ? <p className="artifacts-muted">No history for this file.</p> : snapshot.history.map((commit) => <HistoryRow key={commit.sha} commit={commit} active={commit.sha === snapshot.selectedCommit} path={snapshot.file?.path} diff={snapshot.diff} onSelect={() => void store.selectCommit(commit)} />)}
        </section>
      </main>
    </div>
  );
}
function HistoryRow({ commit, active, path, diff, onSelect }: { commit: ArtifactCommit; active: boolean; path?: string; diff?: { before?: { content: string }; after: { content: string } }; onSelect: () => void }) {
  return <article className={`artifacts-commit${active ? " is-active" : ""}`}><button type="button" className="artifacts-commit-button" onClick={onSelect}><span className="artifacts-commit-meta"><strong>{commit.message}</strong><time>{new Date(commit.time).toLocaleString()}</time></span><span className="artifacts-trailers">{commit.authorName} · {commit.trailers.session ?? "session unknown"} · {commit.trailers.machine ?? "machine unknown"} · {commit.trailers.harness ?? "harness unknown"}</span></button>{active && path && diff ? <div className="artifacts-diff"><FileDiff fileDiff={patchFor(path, diff.before?.content ?? "", diff.after.content)} options={{ theme: "github-dark", disableFileHeader: true }} disableWorkerPool /></div> : null}</article>;
}
