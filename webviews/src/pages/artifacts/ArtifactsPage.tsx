// The Artifacts page: what agents saved and synced (artifacts, memories, notes) as a keyboard-first
// tree (ui/Tree), the chosen file's preview and its history. HTML previews draw in a scriptless,
// sandboxed srcdoc, as the agent pane's passive artifacts do, so a saved document can never reach
// the page, its bridge or the network. Choosing a revision shows its change against its parent.
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { galleryArtifactDocument } from "../../agent-session/acpmux/conversation/artifactSandbox";
import { FileIcon } from "../../file-icons";
import { Tree, type TreeLine } from "../../ui/Tree";
import { lineHunks } from "./lineDiff";
import type { Strings } from "../shared/i18n";
import { textOf, type ArtifactsFailure, type ArtifactsSnapshot, type ArtifactsStore } from "./store";
import type { ArtifactCommit, ArtifactFile } from "./types";

export function ArtifactsPage({ store, strings }: { store: ArtifactsStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  if (snapshot.status === "unavailable") return <p className="artifacts-message">{t("artifacts.page.unavailable")}</p>;
  if (snapshot.status === "idle" || snapshot.status === "loading")
    return <p className="artifacts-message artifacts-muted">{t("artifacts.page.loading")}</p>;
  if (snapshot.status === "failed")
    return (
      <div className="artifacts-message" role="alert">
        <p>{failureText(snapshot.failure, strings)}</p>
        <button type="button" className="artifacts-retry" onClick={() => void store.start()}>
          {t("artifacts.page.retry")}
        </button>
      </div>
    );
  if (snapshot.status === "empty")
    return <p className="artifacts-message artifacts-muted">{t("artifacts.page.empty")}</p>;
  return (
    <div className="artifacts">
      <aside className="artifacts-side">
        <header className="artifacts-header">
          <h1 className="artifacts-title">{t("artifacts.page.title")}</h1>
        </header>
        <FileTree snapshot={snapshot} store={store} strings={strings} />
      </aside>
      <section className="artifacts-main">
        <header className="artifacts-header">
          <span className="artifacts-path">{snapshot.selected ?? t("artifacts.file.choose")}</span>
        </header>
        <Preview snapshot={snapshot} strings={strings} />
        <History snapshot={snapshot} store={store} strings={strings} />
      </section>
    </div>
  );
}

/** Every folder of `paths`, so the tree opens fully at first. */
function foldersOf(paths: readonly string[]): Set<string> {
  const folders = new Set<string>();
  for (const path of paths) {
    const parts = path.split("/");
    for (let end = 1; end < parts.length; end++) folders.add(parts.slice(0, end).join("/"));
  }
  return folders;
}

function FileTree({
  snapshot,
  store,
  strings,
}: {
  snapshot: ArtifactsSnapshot;
  store: ArtifactsStore;
  strings: Strings;
}) {
  const { paths, selected } = snapshot;
  const [expanded, setExpanded] = useState(() => foldersOf(paths));
  const [focused, setFocused] = useState(selected);
  useEffect(() => setExpanded(foldersOf(paths)), [paths]);
  // The store may choose another file (a refresh removed this one): the tree follows it.
  useEffect(() => setFocused(selected), [selected]);
  const files = useMemo(() => new Set(paths), [paths]);
  const lines = useMemo(() => {
    // Children by folder, folders before files, each sorted by name.
    const children = new Map<string, { name: string; path: string; folder: boolean }[]>();
    const add = (parent: string, name: string, path: string, folder: boolean) => {
      const list = children.get(parent) ?? [];
      if (!list.some((entry) => entry.path === path)) list.push({ name, path, folder });
      children.set(parent, list);
    };
    for (const path of paths) {
      const parts = path.split("/");
      parts.forEach((name, index) => {
        add(parts.slice(0, index).join("/"), name, parts.slice(0, index + 1).join("/"), index < parts.length - 1);
      });
    }
    const out: TreeLine[] = [];
    const walk = (folder: string, depth: number) => {
      const entries = (children.get(folder) ?? []).sort(
        (a, b) => Number(b.folder) - Number(a.folder) || a.name.localeCompare(b.name),
      );
      for (const entry of entries) {
        const open = entry.folder && expanded.has(entry.path);
        out.push({
          kind: "item",
          key: entry.path,
          depth,
          text: entry.name,
          expandable: entry.folder,
          expanded: open,
          content: (
            <>
              <span
                className={`artifacts-chevron${entry.folder ? "" : " is-leaf"}${open ? " is-open" : ""}`}
                aria-hidden="true"
              />
              {entry.folder ? <span className="artifacts-folder" aria-hidden="true" /> : <FileIcon path={entry.name} />}
              <span className="artifacts-name">{entry.name}</span>
            </>
          ),
        });
        if (open) walk(entry.path, depth + 1);
      }
    };
    walk("", 0);
    if (snapshot.truncated)
      out.push({
        kind: "note",
        key: "truncated",
        content: <p className="artifacts-note">{strings.t("artifacts.page.truncated")}</p>,
      });
    return out;
  }, [paths, expanded, snapshot.truncated, strings]);
  const toggle = (path: string, open: boolean) =>
    setExpanded((current) => {
      const next = new Set(current);
      if (open) next.add(path);
      else next.delete(path);
      return next;
    });
  return (
    <div className="artifacts-scroll">
      <Tree
        lines={lines}
        selected={focused ?? selected}
        label={strings.t("artifacts.page.title")}
        className="artifacts-tree"
        rowClassName="artifacts-row"
        rowStyle={(item) => ({ paddingInlineStart: 8 + item.depth * 14 })}
        onSelect={(path) => {
          setFocused(path);
          if (files.has(path)) void store.select(path);
        }}
        onExpand={toggle}
        onActivate={(item) => {
          if (item.expandable) toggle(item.key, !item.expanded);
          else void store.select(item.key);
        }}
      />
    </div>
  );
}

function Preview({ snapshot, strings }: { snapshot: ArtifactsSnapshot; strings: Strings }) {
  const { file, fileLoading, fileFailure } = snapshot;
  if (fileFailure && !file)
    return (
      <p className="artifacts-message" role="alert">
        {failureText(fileFailure, strings)}
      </p>
    );
  if (fileLoading || !snapshot.selected)
    return <div className="artifacts-preview artifacts-muted" aria-busy={fileLoading} />;
  if (!file) return <div className="artifacts-preview" />;
  if (file.tooLarge) return <p className="artifacts-message artifacts-muted">{strings.t("artifacts.file.tooLarge")}</p>;
  const text = textOf(file);
  if (text === undefined)
    return <p className="artifacts-message artifacts-muted">{strings.t("artifacts.file.binary")}</p>;
  if (isHtml(file))
    return (
      <iframe
        // A new frame per document: a passive srcdoc frame refuses to be replaced (CEF and WebKit).
        key={`${file.path}@${file.commit}`}
        className="artifacts-preview artifacts-frame"
        title={file.path}
        srcDoc={galleryArtifactDocument(text, "")}
        sandbox=""
        referrerPolicy="no-referrer"
      />
    );
  return <pre className="artifacts-preview artifacts-text">{text}</pre>;
}

function isHtml(file: ArtifactFile): boolean {
  return /^text\/html\b/i.test(file.contentType) || /\.html?$/i.test(file.path);
}

function History({
  snapshot,
  store,
  strings,
}: {
  snapshot: ArtifactsSnapshot;
  store: ArtifactsStore;
  strings: Strings;
}) {
  const { history, selectedCommit, diff, fileFailure, file } = snapshot;
  if (!snapshot.selected || snapshot.fileLoading) return null;
  return (
    <section className="artifacts-history" aria-label={strings.t("artifacts.history.title")}>
      <h2 className="artifacts-history-title">{strings.t("artifacts.history.title")}</h2>
      {history.length === 0 ? <p className="artifacts-muted">{strings.t("artifacts.history.none")}</p> : null}
      <ol className="artifacts-commits">
        {history.map((commit) => {
          const active = commit.sha === selectedCommit;
          return (
            <li key={commit.sha} className={`artifacts-commit${active ? " is-active" : ""}`}>
              <button
                type="button"
                className="artifacts-commit-button"
                aria-pressed={active}
                onClick={() => void store.selectCommit(commit)}
              >
                <span className="artifacts-commit-message">{commit.message}</span>
                <time className="artifacts-muted" dateTime={new Date(commit.time).toISOString()}>
                  {formatTime(commit.time, strings.language)}
                </time>
                <span className="artifacts-trailers artifacts-muted">{trailers(commit)}</span>
              </button>
              {active && file && fileFailure ? (
                <p className="artifacts-note" role="alert">
                  {failureText(fileFailure, strings)}
                </p>
              ) : null}
              {active && diff?.sha === commit.sha ? (
                <Change before={diff.before} after={diff.after} strings={strings} />
              ) : null}
            </li>
          );
        })}
      </ol>
    </section>
  );
}

/** The revision's change to the file, as unified lines with a little context. */
function Change({ before, after, strings }: { before?: string; after: string; strings: Strings }) {
  const hunks = useMemo(() => lineHunks(before ?? "", after), [before, after]);
  if (hunks.length === 0) return <p className="artifacts-note">{strings.t("artifacts.history.unchanged")}</p>;
  return (
    <div className="artifacts-diff">
      {hunks.map((hunk, index) => (
        <div key={index} className="artifacts-hunk">
          {hunk.map((line, row) => (
            <div key={row} className={`artifacts-line is-${line.type}`}>
              <span className="artifacts-sign" aria-hidden="true">
                {line.type === "add" ? "+" : line.type === "del" ? "-" : " "}
              </span>
              {line.text}
              {line.noNewline ? (
                <span className="artifacts-no-newline">{strings.t("artifacts.history.noNewline")}</span>
              ) : null}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

/** Who saved a revision: its harness, machine and session, as the saver gave them. */
function trailers(commit: ArtifactCommit): string {
  const { harness, machine, session } = commit.trailers;
  return [harness, machine, session].filter(Boolean).join(" · ") || commit.authorName;
}

function formatTime(time: number, language: string): string {
  return new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(new Date(time));
}

/** The app's own words for a failure (it words them in the person's language), else the page's. */
function failureText(failure: ArtifactsFailure | undefined, strings: Strings): string {
  return failure?.message ?? strings.t("artifacts.page.failed");
}
