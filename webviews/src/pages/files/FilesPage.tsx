// The Files page (cx-p4rt): the chat's folder as a keyboard-first tree beside the chat (ui/Tree: Up
// and Down move, Right opens a folder or steps into it, Left closes it or steps to its parent, Return
// opens a file or toggles a folder, Home and End jump, typing selects by name). Folders list as git
// sees them, so ignored files never show.
import { useSyncExternalStore } from "react";
import { FileIcon } from "../../file-icons";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Tree, type TreeLine } from "../../ui/Tree";
import type { Strings } from "../shared/i18n";
import { joinPath, type FilesStore, type FolderState, type Row } from "./store";

export function FilesPage({ store, strings }: { store: FilesStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { rows, selected, root, folders, expanded } = snapshot;

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
            {directory ? <span className="files-folder" aria-hidden="true" /> : <FileIcon path={entry.name} />}
            <span className="files-name">{entry.name}</span>
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

  return (
    <div className="files">
      <header className="files-header">{root.name}</header>
      <div className="files-scroll" data-page-scroll="tree">
        <ContextMenu items={menu(current)} className="files-menu">
          <Tree
            lines={linesOf("", 0)}
            selected={selected}
            label={root.name}
            className="files-tree"
            rowClassName="files-row"
            rowStyle={(item) => ({ paddingInlineStart: 8 + item.depth * 14 })}
            onSelect={(path) => store.select(path)}
            onExpand={(path, open) => (open ? store.expand(path) : store.collapse(path))}
            onActivate={(item) => {
              const row = rows.find((candidate) => candidate.path === item.key);
              if (row) activate(row);
            }}
          />
        </ContextMenu>
      </div>
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
