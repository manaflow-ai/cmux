// The Files page (cx-p4rt): the chat's folder as a keyboard-first tree beside the chat (ui/Tree: Up
// and Down move, Right opens a folder or steps into it, Left closes it or steps to its parent, Return
// opens a file or toggles a folder, Home and End jump, typing selects by name). Folders list as git
// sees them, then what git ignores, greyed out. The header searches the folder (a flat list of
// matches while it holds text; Escape clears it) and refreshes it (Lucas 2026-10-17).
import { useSyncExternalStore } from "react";
import { FileIcon } from "../../file-icons";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Tree, type TreeLine } from "../../ui/Tree";
import { inputCommandProps } from "../../ui/inputCommandProps";
import type { Strings } from "../shared/i18n";
import { joinPath, type FilesStore, type FolderState, type Row } from "./store";

export function FilesPage({ store, strings }: { store: FilesStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { rows, selected, root, folders, expanded, query, results } = snapshot;

  if (snapshot.unavailable) return <p className="files-message">{strings.t("files.page.unavailable")}</p>;
  if (snapshot.failed) return <p className="files-message">{snapshot.failed}</p>;
  if (!root) return <p className="files-message files-muted">{strings.t("files.page.loading")}</p>;

  const current = rows.find((row) => row.path === selected);
  const activate = (row: Row) => (row.kind === "directory" ? store.toggle(row.path) : void store.open(row.path));

  const menu = (row: Row | undefined): ContextMenuItem[] => {
    const path = row?.path ?? "";
    const absolute = store.absolutePath(path) ?? "";
    const items: ContextMenuItem[] = [];
    if (row) {
      items.push({
        id: "open",
        label: strings.t(
          row.kind === "directory" ? (row.expanded ? "files.menu.collapse" : "files.menu.expand") : "files.menu.open",
        ),
        onSelect: () => activate(row),
      });
    }
    items.push(
      {
        id: "copyPath",
        label: strings.t("files.menu.copyPath"),
        separatorBefore: !!row,
        onSelect: () => void store.copy(absolute),
      },
      ...(row
        ? [
            {
              id: "copyRelative",
              label: strings.t("files.menu.copyRelativePath"),
              onSelect: () => void store.copy(path),
            },
          ]
        : []),
      {
        id: "refresh",
        label: strings.t("files.menu.refresh"),
        separatorBefore: true,
        onSelect: () => void store.refresh(),
      },
    );
    return items;
  };

  // A folder's rows, each open folder's rows under it, then the folder's own status line after them.
  const linesOf = (folder: string, depth: number): TreeLine[] => {
    const state = folders.get(folder);
    const lines: TreeLine[] = [];
    for (const entry of state?.entries ?? []) {
      const path = joinPath(folder, entry.name);
      const directory = entry.kind === "directory";
      const open = directory && expanded.has(path);
      const dim = entry.ignored ? " is-ignored" : "";
      lines.push({
        kind: "item",
        key: path,
        depth,
        text: entry.name,
        expandable: directory,
        expanded: open,
        content: (
          <>
            <span
              className={`files-chevron${directory ? "" : " is-leaf"}${open ? " is-open" : ""}`}
              aria-hidden="true"
            />
            {directory ? (
              <span className={`files-folder${dim}`} aria-hidden="true" />
            ) : (
              <span className={`files-icon${dim}`} aria-hidden="true">
                <FileIcon path={entry.name} />
              </span>
            )}
            <span className={`files-name${dim}`}>{entry.name}</span>
          </>
        ),
      });
      if (open) lines.push(...linesOf(path, depth + 1));
    }
    const status = statusText(state, strings);
    if (status) {
      lines.push({
        kind: "note",
        key: `status:${folder}`,
        content: (
          <div
            className={`files-status${state?.failed ? " is-failed" : ""}`}
            style={{ paddingInlineStart: 30 + depth * 14 }}
          >
            {status}
          </div>
        ),
      });
    }
    return lines;
  };

  // While the search field holds text, its matches as one flat list (a match opens its file).
  const searching = query.trim().length > 0;
  const resultLines = (): TreeLine[] =>
    results === undefined
      ? [
          {
            kind: "note",
            key: "searching",
            content: <div className="files-status">{strings.t("files.page.loading")}</div>,
          },
        ]
      : results.length === 0
        ? [
            {
              kind: "note",
              key: "none",
              content: <div className="files-status">{strings.t("files.page.noResults")}</div>,
            },
          ]
        : results.map((path) => {
            const name = path.split("/").pop() ?? path;
            const folder = path.slice(0, Math.max(0, path.length - name.length - 1));
            return {
              kind: "item" as const,
              key: path,
              depth: 0,
              text: name,
              expandable: false,
              expanded: false,
              content: (
                <>
                  <span className="files-icon" aria-hidden="true">
                    <FileIcon path={name} />
                  </span>
                  <span className="files-name">{name}</span>
                  {folder && <span className="files-where">{folder}</span>}
                </>
              ),
            };
          });

  return (
    <div className="files">
      {/* The tab names the folder already: the page starts with its search and Refresh. */}
      <div className="files-bar">
        <div className="files-search">
          <svg
            width="13"
            height="13"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.3"
            strokeLinecap="round"
            aria-hidden="true"
          >
            <circle cx="7" cy="7" r="4.5" />
            <path d="M10.4 10.4 13.5 13.5" />
          </svg>
          <input
            className="files-search-field"
            type="search"
            value={query}
            placeholder={strings.t("files.page.search")}
            aria-label={strings.t("files.page.search")}
            spellCheck={false}
            onChange={(event) => void store.search(event.currentTarget.value)}
            {...inputCommandProps({
              escape: (event) => {
                if (query) {
                  event.preventDefault();
                  void store.search("");
                }
              },
            })}
          />
        </div>
        <button
          type="button"
          className="files-refresh"
          aria-label={strings.t("files.menu.refresh")}
          title={strings.t("files.menu.refresh")}
          onClick={() => void store.refresh()}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.3"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="M13.25 8a5.25 5.25 0 1 1-1.54-3.71" />
            <path d="M13.25 2.75v2.75H10.5" />
          </svg>
        </button>
      </div>
      <ContextMenu items={menu(current)} className="files-scroll">
        <Tree
          lines={searching ? resultLines() : linesOf("", 0)}
          selected={selected}
          label={root.name}
          className="files-tree"
          rowClassName="files-row"
          rowStyle={(item) => ({ paddingInlineStart: 8 + item.depth * 14 })}
          onSelect={(path) => store.select(path)}
          onExpand={(path, open) => (open ? store.expand(path) : store.collapse(path))}
          onActivate={(item) => {
            if (searching) return void store.open(item.key);
            const row = rows.find((candidate) => candidate.path === item.key);
            if (row) activate(row);
          }}
        />
      </ContextMenu>
      {snapshot.notice ? <p className="files-status is-failed files-notice">{snapshot.notice}</p> : null}
    </div>
  );
}

/** The muted line under a folder that is loading, empty, cut short or failed to list. */
function statusText(state: FolderState | undefined, strings: Strings): string | undefined {
  const empty = !state?.entries?.length;
  if (state?.failed) return state.failed;
  if (state?.loading && empty) return strings.t("files.page.loading");
  if (state?.truncated) return strings.t("files.page.truncated");
  if (state?.entries && empty) return strings.t("files.page.empty");
  return undefined;
}
