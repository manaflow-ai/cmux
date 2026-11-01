// The Artifacts page: what agents saved and synced (artifacts, memories, notes) as a keyboard-first
// tree (ui/Tree) and the chosen file's text. Every file previews as plain text for now: rendered
// previews (sandboxed HTML, images) and the file's history come with later slices of #27823.
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { FileIcon } from "../../file-icons";
import { Tree, type TreeLine } from "../../ui/Tree";
import type { Strings } from "../shared/i18n";
import { textOf, type ArtifactsFailure, type ArtifactsSnapshot, type ArtifactsStore } from "./store";
import type { ArtifactFile } from "./types";

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
  return (
    <>
      {/* A reload that failed keeps the file it had on screen and says so; a refresh tries again. */}
      {fileFailure ? (
        <p className="artifacts-note" role="alert">
          {failureText(fileFailure, strings)}
        </p>
      ) : null}
      <FileBody file={file} strings={strings} />
    </>
  );
}

function FileBody({ file, strings }: { file: ArtifactFile; strings: Strings }) {
  if (file.tooLarge) return <p className="artifacts-message artifacts-muted">{strings.t("artifacts.file.tooLarge")}</p>;
  const text = textOf(file);
  if (text === undefined)
    return <p className="artifacts-message artifacts-muted">{strings.t("artifacts.file.binary")}</p>;
  return <pre className="artifacts-preview artifacts-text">{text}</pre>;
}

/** The app's own words for a failure (it words them in the person's language), else the page's. */
function failureText(failure: ArtifactsFailure | undefined, strings: Strings): string {
  return failure?.message ?? strings.t("artifacts.page.failed");
}
