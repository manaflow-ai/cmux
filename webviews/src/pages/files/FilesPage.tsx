// The Files page (cx-p4rt): the chat's folder as a keyboard-first tree beside the chat. Up and Down
// move, Right opens a folder or steps into it, Left closes it or steps to its parent, Return opens a
// file or toggles a folder, Home and End jump, and typing a name selects the next row that starts
// with it. Folders list as git sees them, so ignored files never show.
import { useEffect, useRef, useSyncExternalStore, type KeyboardEvent, type ReactNode } from "react";
import { FileIcon } from "../../file-icons";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import type { Strings } from "../shared/i18n";
import { joinPath, parentPath, type FilesStore, type FolderState, type Row } from "./store";

const TYPEAHEAD_MS = 600;
const rowId = (path: string) => `files-row-${encodeURIComponent(path)}`;

export function FilesPage({ store, strings }: { store: FilesStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const tree = useRef<HTMLDivElement>(null);
  const typed = useRef({ text: "", at: 0 });
  const { rows, selected, root, folders, expanded } = snapshot;
  const index = rows.findIndex((row) => row.path === selected);
  const current = index >= 0 ? rows[index] : undefined;

  // The selected row stays in view as the keys move it.
  useEffect(() => {
    if (selected !== undefined) document.getElementById(rowId(selected))?.scrollIntoView({ block: "nearest" });
  }, [selected]);

  // The tree takes the keys as soon as it shows, and again whenever the tab's window comes forward.
  const ready = root !== undefined;
  useEffect(() => {
    if (!ready) return;
    const focus = () => tree.current?.focus({ preventScroll: true });
    focus();
    window.addEventListener("focus", focus);
    return () => window.removeEventListener("focus", focus);
  }, [ready]);

  if (snapshot.unavailable) return <p className="files-message">{strings.t("files.page.unavailable")}</p>;
  if (snapshot.failed) return <p className="files-message">{snapshot.failed}</p>;
  if (!root) return <p className="files-message files-muted">{strings.t("files.page.loading")}</p>;

  const activate = (row: Row) => (row.kind === "directory" ? store.toggle(row.path) : void store.open(row.path));
  const move = (to: number) => {
    const row = rows[Math.max(0, Math.min(rows.length - 1, to))];
    if (row) store.select(row.path);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const handled = (() => {
      switch (event.key) {
        case "ArrowDown":
          return (move(index + 1), true);
        case "ArrowUp":
          return (move(index < 0 ? 0 : index - 1), true);
        case "Home":
          return (move(0), true);
        case "End":
          return (move(rows.length - 1), true);
        case "ArrowRight":
          if (current?.kind !== "directory") return false;
          if (current.expanded) move(index + 1);
          else store.expand(current.path);
          return true;
        case "ArrowLeft":
          if (!current) return false;
          if (current.expanded) store.collapse(current.path);
          else if (current.depth > 0) store.select(parentPath(current.path));
          return true;
        case "Enter":
        case " ":
          return current ? (activate(current), true) : false;
      }
      if (event.key.length !== 1) return false;
      // Type-ahead: the next row whose name starts with what was typed.
      const now = event.timeStamp;
      const text = (now - typed.current.at < TYPEAHEAD_MS ? typed.current.text : "") + event.key.toLowerCase();
      typed.current = { text, at: now };
      const start = text.length === 1 ? index + 1 : Math.max(0, index);
      const order = [...rows.slice(start), ...rows.slice(0, start)];
      const match = order.find((row) => row.name.toLowerCase().startsWith(text));
      if (match) store.select(match.path);
      return true;
    })();
    if (handled) event.preventDefault();
  };

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
  const renderFolder = (folder: string, depth: number): ReactNode[] => {
    const state = folders.get(folder);
    const nodes: ReactNode[] = [];
    for (const entry of state?.entries ?? []) {
      const path = joinPath(folder, entry.name);
      const row = {
        path,
        name: entry.name,
        kind: entry.kind,
        depth,
        expanded: entry.kind === "directory" && expanded.has(path),
      };
      nodes.push(
        <FilesRow
          key={path}
          row={row}
          selected={path === selected}
          onPointerDown={() => {
            store.select(path);
            tree.current?.focus({ preventScroll: true });
          }}
          onClick={() => row.kind === "directory" && store.toggle(path)}
          onDoubleClick={() => row.kind === "file" && void store.open(path)}
        />,
      );
      if (row.expanded) nodes.push(...renderFolder(path, depth + 1));
    }
    nodes.push(
      <FolderStatus
        key={`status:${folder}`}
        state={state}
        depth={depth}
        strings={strings}
        empty={!state?.entries?.length}
      />,
    );
    return nodes;
  };

  return (
    <div className="files">
      <header className="files-header" title={root.folder}>
        {root.name}
      </header>
      <ContextMenu items={menu(current)} className="files-scroll">
        <div
          ref={tree}
          className="files-tree"
          role="tree"
          aria-label={root.name}
          tabIndex={0}
          aria-activedescendant={selected !== undefined ? rowId(selected) : undefined}
          onKeyDown={onKeyDown}
        >
          {renderFolder("", 0)}
        </div>
      </ContextMenu>
      {snapshot.notice ? <p className="files-status is-failed files-notice">{snapshot.notice}</p> : null}
    </div>
  );
}

function FilesRow({
  row,
  selected,
  onPointerDown,
  onClick,
  onDoubleClick,
}: {
  row: Row;
  selected: boolean;
  onPointerDown: () => void;
  onClick: () => void;
  onDoubleClick: () => void;
}) {
  const directory = row.kind === "directory";
  return (
    // The tree owns focus and every key (aria-activedescendant), so a row takes only the pointer.
    // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/interactive-supports-focus
    <div
      id={rowId(row.path)}
      className={`files-row${selected ? " is-selected" : ""}`}
      role="treeitem"
      aria-level={row.depth + 1}
      aria-selected={selected}
      aria-expanded={directory ? row.expanded : undefined}
      style={{ paddingInlineStart: 8 + row.depth * 14 }}
      onPointerDown={onPointerDown}
      onClick={onClick}
      onDoubleClick={onDoubleClick}
    >
      <span
        className={`files-chevron${directory ? "" : " is-leaf"}${row.expanded ? " is-open" : ""}`}
        aria-hidden="true"
      />
      {directory ? <span className="files-folder" aria-hidden="true" /> : <FileIcon path={row.name} />}
      <span className="files-name">{row.name}</span>
    </div>
  );
}

/** The muted line under a folder that is loading, empty, cut short or failed to list. */
function FolderStatus({
  state,
  depth,
  strings,
  empty,
}: {
  state?: FolderState;
  depth: number;
  strings: Strings;
  empty: boolean;
}) {
  let text: ReactNode = null;
  if (state?.failed) text = state.failed;
  else if (state?.loading && empty) text = strings.t("files.page.loading");
  else if (state?.truncated) text = strings.t("files.page.truncated");
  else if (state?.entries && empty) text = strings.t("files.page.empty");
  if (!text) return null;
  return (
    <div className={`files-status${state?.failed ? " is-failed" : ""}`} style={{ paddingInlineStart: 30 + depth * 14 }}>
      {text}
    </div>
  );
}
