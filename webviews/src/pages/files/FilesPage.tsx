// The Files page (cx-p4rt): the chat's folder as a keyboard-first tree beside the chat (ui/Tree: Up
// and Down move, Right opens a folder or steps into it, Left closes it or steps to its parent, Return
// opens a file or toggles a folder, Home and End jump, typing selects by name). Any folder lists:
// in a git repository as git sees it (ignored files never show), elsewhere from the disk.
import { useMemo, useSyncExternalStore } from "react";
import { FileIcon } from "../../file-icons";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Tree, useTreeLineCache, type TreeLine, type TreeLineBuilder } from "../../ui/Tree";
import type { Strings } from "../shared/i18n";
import { joinPath, type FilesSnapshot, type FilesStore, type FolderState, type Row } from "./store";

export function FilesPage({ store, strings }: { store: FilesStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { rows, selected, root, folders, expanded } = snapshot;
  // The lines change with the listings and the open folders, not with the selection; each keeps its
  // object while its entry is the same, so the tree draws again only the rows that changed.
  const cache = useTreeLineCache();
  const lines = useMemo(
    () => cache.build((line) => linesOf(line, folders, expanded, strings, "", 0)),
    [cache, folders, expanded, strings],
  );
  const byPath = useMemo(() => new Map(rows.map((row) => [row.path, row])), [rows]);

  if (snapshot.unavailable) return <p className="files-message">{strings.t("files.page.unavailable")}</p>;
  if (snapshot.failed) return <p className="files-message">{snapshot.failed}</p>;
  if (!root) return <p className="files-message files-muted">{strings.t("files.page.loading")}</p>;

  const current = selected === undefined ? undefined : byPath.get(selected);
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

  return (
    <div className="files">
      <header className="files-header">{root.name}</header>
      <ContextMenu items={menu(current)} className="files-scroll">
        <Tree
          lines={lines}
          selected={selected}
          label={root.name}
          className="files-tree"
          rowClassName="files-row"
          rowStyle={(item) => ({ paddingInlineStart: 8 + item.depth * 14 })}
          onSelect={(path) => store.select(path)}
          onExpand={(path, open) => (open ? store.expand(path) : store.collapse(path))}
          onActivate={(item) => {
            const row = byPath.get(item.key);
            if (row) activate(row);
          }}
        />
      </ContextMenu>
      {snapshot.notice ? <p className="files-status is-failed files-notice">{snapshot.notice}</p> : null}
    </div>
  );
}

/** A folder's rows, each open folder's rows under it, then the folder's own status line after them. */
function linesOf(
  line: TreeLineBuilder,
  folders: FilesSnapshot["folders"],
  expanded: FilesSnapshot["expanded"],
  strings: Strings,
  folder: string,
  depth: number,
  lines: TreeLine[] = [],
): TreeLine[] {
  const state = folders.get(folder);
  for (const entry of state?.entries ?? []) {
    const path = joinPath(folder, entry.name);
    const directory = entry.kind === "directory";
    const open = directory && expanded.has(path);
    lines.push(
      line.item({ key: path, depth, text: entry.name, expandable: directory, expanded: open }, [], () => (
        <>
          <span className={`files-chevron${directory ? "" : " is-leaf"}${open ? " is-open" : ""}`} aria-hidden="true" />
          {directory ? <span className="files-folder" aria-hidden="true" /> : <FileIcon path={entry.name} />}
          <span className="files-name">{entry.name}</span>
        </>
      )),
    );
    if (open) linesOf(line, folders, expanded, strings, path, depth + 1, lines);
  }
  const status = statusText(state, strings);
  if (status) {
    const failed = !!state?.failed;
    lines.push(
      line.note(`status:${folder}`, [status, failed, depth], () => (
        <div className={`files-status${failed ? " is-failed" : ""}`} style={{ paddingInlineStart: 30 + depth * 14 }}>
          {status}
        </div>
      )),
    );
  }
  return lines;
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
