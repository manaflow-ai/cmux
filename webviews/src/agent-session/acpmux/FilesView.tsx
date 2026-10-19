// The chat's folder in the chat's viewer (labs `chatViewer`, Lucas 2026-10-19): the header's Files
// opens here, beside the transcript, instead of a file tree in a new column that scrolls the chat and
// its tabs out of view. A folder opens in place; a file opens in the viewer (FileViewer.tsx), whose
// Back returns here. Listing is the session host's `git.files.list` (`file.list`), search its
// `git.files.search` (`file.search`), so ignored files never show.
import type { KeyboardEvent } from "react";
import { useEffect, useRef, useState } from "react";
import { useT } from "./i18n";
import { ChevronLeft } from "./changeIcons";
import { FileDoc, Folder } from "./conversation/icons";
import { Icon } from "./icons/Icon";

export type FilesEntry = { name: string; kind: string };

/// The reads the view makes; the App answers them with `file.list` and `file.search`.
export type FilesSource = {
  list(folder: string): Promise<{ entries?: FilesEntry[]; truncated?: boolean } | null | undefined>;
  search(
    query: string,
  ): Promise<{ results?: { path: string }[]; search_root?: string; root?: string } | null | undefined>;
};

type Shown =
  | { kind: "loading" }
  | { kind: "entries"; entries: FilesEntry[] }
  | { kind: "outside" }
  | { kind: "failed" };

/// A read that failed because the folder is in no git repository (the session host's reason).
const outsideRepository = (error: unknown) =>
  /not[ _-]?(in )?a[ _-]?(git )?repository/i.test(String((error as Error)?.message ?? error));

export function FilesView({
  root,
  folder,
  source,
  onFolder,
  onOpen,
  onClose,
}: {
  /// The chat's folder: the top the view never goes above.
  root: string;
  folder: string;
  source: FilesSource;
  onFolder(folder: string): void;
  onOpen(path: string): void;
  onClose(): void;
}) {
  const t = useT();
  const back = useRef<HTMLButtonElement>(null);
  const [shown, setShown] = useState<Shown>({ kind: "loading" });
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<{ base: string; paths: string[] } | "failed" | undefined>();
  useEffect(() => back.current?.focus({ preventScroll: true }), []);
  useEffect(() => {
    let current = true;
    setShown({ kind: "loading" });
    source.list(folder).then(
      (reply) => current && setShown({ kind: "entries", entries: reply?.entries ?? [] }),
      (error: unknown) => current && setShown({ kind: outsideRepository(error) ? "outside" : "failed" }),
    );
    return () => {
      current = false;
    };
  }, [folder, source]);
  useEffect(() => {
    const text = query.trim();
    if (!text) return setResults(undefined);
    let current = true;
    source.search(text).then(
      (reply) =>
        current &&
        setResults({
          base: reply?.search_root ?? reply?.root ?? root,
          paths: (reply?.results ?? []).map((result) => result.path),
        }),
      () => current && setResults("failed"),
    );
    return () => {
      current = false;
    };
  }, [query, root, source]);
  const inside = folder.length > root.length ? folder.slice(root.length + 1) : "";
  const name = root.split("/").pop() || root;
  const parent = inside ? folder.slice(0, folder.lastIndexOf("/")) : undefined;
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    event.preventDefault();
    if (query) setQuery("");
    else onClose();
  };
  const row = (key: string, label: string, folderRow: boolean, onClick: () => void) => (
    <li key={key}>
      <button type="button" className="acpmux-files-row" onClick={onClick}>
        {folderRow ? <Folder size={15} /> : <FileDoc size={15} />}
        <span className="acpmux-files-name">{label}</span>
      </button>
    </li>
  );
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape clears the search, then closes the viewer.
    <section
      className="acpmux-diff-panel acpmux-file-viewer acpmux-files"
      aria-label={t("header.files")}
      onKeyDown={onKeyDown}
    >
      <header className="acpmux-diff-header">
        <button
          ref={back}
          type="button"
          className="acpmux-diff-back"
          aria-label={t("changes.back")}
          title={t("changes.back")}
          onClick={onClose}
        >
          <ChevronLeft />
        </button>
        <span className="acpmux-file-viewer-name" title={folder}>
          {inside ? `${name}/${inside}` : name}
        </span>
        <button
          type="button"
          className="acpmux-diff-tool"
          aria-label={t("image.close")}
          title={t("image.close")}
          onClick={onClose}
        >
          <Icon name="action.close" size={12} />
        </button>
      </header>
      <div className="acpmux-files-search">
        <input
          type="search"
          value={query}
          placeholder={t("files.search")}
          aria-label={t("files.search")}
          onChange={(event) => setQuery(event.currentTarget.value)}
        />
      </div>
      <div className="acpmux-file-viewer-body">
        {results ? (
          results === "failed" ? (
            <p className="acpmux-file-viewer-note">{t("files.failed")}</p>
          ) : results.paths.length === 0 ? (
            <p className="acpmux-file-viewer-note">{t("files.none")}</p>
          ) : (
            <ul className="acpmux-files-list">
              {results.paths.map((path) => row(path, path, false, () => onOpen(`${results.base}/${path}`)))}
            </ul>
          )
        ) : shown.kind === "entries" ? (
          <ul className="acpmux-files-list">
            {parent !== undefined && row("..", "..", true, () => onFolder(parent))}
            {shown.entries.map((entry) =>
              row(entry.name, entry.name, entry.kind === "directory", () =>
                entry.kind === "directory" ? onFolder(`${folder}/${entry.name}`) : onOpen(`${folder}/${entry.name}`),
              ),
            )}
          </ul>
        ) : shown.kind === "outside" ? (
          <p className="acpmux-file-viewer-note">{t("files.outside")}</p>
        ) : shown.kind === "failed" ? (
          <p className="acpmux-file-viewer-note">{t("files.failed")}</p>
        ) : null}
      </div>
    </section>
  );
}
