// The Bookmarks page (`cmux-page://cmux.bookmarks/`), the Swift manager's (CmuxNextBookmarks
// BookmarkManagerView) behavior on the web: a folder tree beside the folder's list, search with
// folder paths, multi-select, drag to reorder or file, context menus and the editor. State lives
// in `BookmarksStore`; this file only renders it and turns plain keys, clicks and drops into store
// intents. Cmd/Ctrl chords never reach page handlers.
import {
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type DragEvent,
  type KeyboardEvent,
  type MouseEvent,
} from "react";
import { Breadcrumbs } from "../../ui/Breadcrumbs";
import { useLasting } from "../../ui/lasting";
import { Tree, type TreeLine } from "../../ui/Tree";
import { VirtualList } from "../../ui/VirtualList";
import { PageMenu, type PageMenuItem } from "../shared/PageMenu";
import type { Strings } from "../shared/i18n";
import { BookmarkEditor } from "./BookmarkEditor";
import {
  displayURL,
  dropInto,
  dropOnRow,
  folderPath,
  folderTrail,
  hasSubfolders,
  iconKey,
  isRoot,
  moveSelection,
  PATH_SEPARATOR,
  treeRows,
  urlCount,
  type RootTitles,
} from "./model";
import type { BookmarksSnapshot, BookmarksStore, RowIcon } from "./store";
import type { Bookmark } from "./types";

/** `two-pane` ships: the folder tree beside the list (the tree drops below 480 px and the
 * breadcrumb takes its place). `breadcrumb` and `compact` are gallery alternatives. */
export type BookmarksLayout = "two-pane" | "breadcrumb" | "compact";

/** Every row is this tall, so the list virtualizes on fixed offsets and nothing reflows. */
const ROW_HEIGHT: Record<BookmarksLayout, number> = { "two-pane": 28, breadcrumb: 28, compact: 24 };
const DRAG_TYPE = "application/x-cmux-bookmarks";

type OpenMenu = { session: number; x: number; y: number; items: PageMenuItem[]; returnFocus: HTMLElement | null };
type DropMark = { id: string; kind: "before" | "into" } | null;

// A stable callback ref: React calls it only when the node mounts.
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

/** A plain key: no Cmd, Ctrl or Option (those belong to the app's key dispatcher). */
function plain(event: KeyboardEvent): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}

export function BookmarksPage({
  store,
  strings,
  layout = "two-pane",
}: {
  store: BookmarksStore;
  strings: Strings;
  layout?: BookmarksLayout;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const [dropMark, setDropMark] = useState<DropMark>(null);
  // Even when two native menus open before the first reply, each owns its own actions.
  const menuSession = useRef(0);
  const dragged = useRef<string[]>([]);
  const { t, format } = strings;
  // The host's root titles, else the page's own (a host that has not answered yet).
  const titles: RootTitles = {
    bar: snap.titles.bar || t("root.bar"),
    other: snap.titles.other || t("root.other"),
  };
  // A lost host shows nothing until it lasts past the grace (a launch, a daemon restart: the store
  // re-reads once the link is back); then the disconnected line.
  const down = snap.connection === "disconnected";
  const downLasting = useLasting(down);
  const searching = snap.results !== null;
  const rows = snap.rows;
  const focusIndex = snap.focus === undefined ? -1 : rows.findIndex((row) => row.id === snap.focus);

  const openMenu = (event: MouseEvent, items: PageMenuItem[]) => {
    event.preventDefault();
    event.stopPropagation();
    setMenu({
      session: ++menuSession.current,
      x: event.clientX,
      y: event.clientY,
      items,
      returnFocus: event.currentTarget instanceof HTMLElement ? event.currentTarget : null,
    });
  };

  const addItems = (): PageMenuItem[] => [
    { id: "addBookmark", label: t("verb.addBookmark"), run: () => store.startAddBookmark() },
    { id: "addFolder", label: t("verb.addFolder"), run: () => store.startAddFolder() },
  ];

  const moreItems = (): PageMenuItem[] => [
    ...addItems(),
    { id: "import", label: t("verb.import"), separatorBefore: true, run: () => void store.importFile() },
    { id: "importFromBrowser", label: t("verb.importFromBrowser"), run: () => void store.importFromBrowser() },
    { id: "export", label: t("verb.export"), separatorBefore: true, run: () => void store.exportFile() },
  ];

  const nodeItems = (node: Bookmark, selection: readonly string[]): PageMenuItem[] => {
    const remove: PageMenuItem = {
      id: "delete",
      label: t("verb.delete"),
      destructive: true,
      separatorBefore: true,
      run: () => void store.deleteSelection(selection),
    };
    if (selection.length > 1) return [{ ...remove, separatorBefore: false }];
    const items: PageMenuItem[] = [];
    if (node.kind === "folder") {
      const count = urlCount(snap.tree, node.id);
      items.push(
        {
          id: "openAll",
          label: format("verb.openAll", String(count)),
          disabled: count === 0,
          run: () => void store.openAll(node),
        },
        { id: "rename", label: t("verb.rename"), run: () => store.startEdit(node) },
      );
      if (snap.canSetFolderIcons) {
        items.push({ id: "setIcon", label: t("verb.setIcon"), run: () => void store.setIcon(node) });
        if (node.icon)
          items.push({ id: "removeIcon", label: t("verb.removeIcon"), run: () => void store.clearIcon(node) });
      }
    } else {
      items.push(
        { id: "open", label: t("verb.open"), run: () => void store.open(node, "current") },
        { id: "openInNewTab", label: t("verb.openInNewTab"), run: () => void store.open(node, "newTab") },
        {
          id: "openInBackgroundTab",
          label: t("verb.openInBackgroundTab"),
          run: () => void store.open(node, "backgroundTab"),
        },
        { id: "edit", label: t("verb.edit"), separatorBefore: true, run: () => store.startEdit(node) },
      );
      if (node.url) items.push({ id: "copyURL", label: t("verb.copyURL"), run: () => void store.copyURL(node) });
    }
    if (searching) items.push({ id: "showInFolder", label: t("verb.showInFolder"), run: () => store.reveal(node.id) });
    items.push(remove);
    return items;
  };

  const rowMenu = (node: Bookmark, event: MouseEvent) => {
    // A right-click outside the selection selects that row alone, as Finder and the Swift list do.
    const selection = snap.selection.includes(node.id) ? snap.selection : [node.id];
    if (selection !== snap.selection) store.select(node.id);
    openMenu(event, nodeItems(node, selection));
  };

  const listKeys = (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const next = moveSelection(rows, snap.focus, event.key === "ArrowDown" ? 1 : -1);
      store.select(next, event.shiftKey ? "range" : "single");
    } else if (event.key === "Enter") {
      const node = focusIndex >= 0 ? rows[focusIndex] : undefined;
      if (!node) return;
      store.activate(node);
    } else return;
    event.preventDefault();
  };

  // Delete and Backspace remove the selection only from the list itself: in the field they edit text.
  const listOnlyKeys = (event: KeyboardEvent) => {
    if (plain(event) && (event.key === "Delete" || event.key === "Backspace") && snap.selection.length > 0) {
      event.preventDefault();
      void store.deleteSelection();
      return;
    }
    listKeys(event);
  };

  const searchKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (plain(event) && event.key === "Escape" && snap.text) {
      store.setText("");
      event.preventDefault();
      return;
    }
    listKeys(event);
  };

  // Drag: a row of the selection carries the whole selection; any other row carries itself.
  const dragStart = (node: Bookmark, event: DragEvent) => {
    const ids = snap.selection.includes(node.id) ? [...snap.selection] : [node.id];
    if (!snap.selection.includes(node.id)) store.select(node.id);
    dragged.current = ids;
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData(DRAG_TYPE, JSON.stringify(ids));
    if (node.url) event.dataTransfer.setData("text/uri-list", node.url);
  };
  const dragEnd = () => {
    dragged.current = [];
    setDropMark(null);
  };
  const overRow = (node: Bookmark, event: DragEvent) => {
    const place = dropOnRow(snap.tree, dragged.current, node);
    if (!place) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    const kind = place.parent === node.id ? "into" : "before";
    if (dropMark?.id !== node.id || dropMark.kind !== kind) setDropMark({ id: node.id, kind });
  };
  const dropRow = (node: Bookmark, event: DragEvent) => {
    event.preventDefault();
    const ids = dragged.current;
    dragEnd();
    void store.dropOnRow(ids, node);
  };
  const overFolder = (folder: string, event: DragEvent) => {
    if (!dropInto(snap.tree, dragged.current, folder)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    if (dropMark?.id !== folder || dropMark.kind !== "into") setDropMark({ id: folder, kind: "into" });
  };
  const dropFolder = (folder: string, event: DragEvent) => {
    event.preventDefault();
    const ids = dragged.current;
    dragEnd();
    void store.dropInto(ids, folder);
  };

  // Icons are asked for only for the rows the list rendered this frame.
  const rendered: Bookmark[] = [];
  useEffect(() => {
    void store.requestIcons(rendered);
  });

  const trail = folderTrail(snap.tree, snap.folder, titles);
  const crumbs = (
    <Breadcrumbs
      className={`bm-crumbs${layout === "two-pane" ? " is-narrow-only" : ""}`}
      crumbClassName="bm-crumb"
      label={t("page.title")}
      crumbs={trail.map((step) => ({ label: step.title, path: step.id }))}
      separator={() => (
        <span className="bm-crumb-separator" aria-hidden="true">
          ›
        </span>
      )}
      onNavigate={(crumb) => store.showFolder(crumb.path)}
    />
  );

  const empty = rows.length === 0;
  const list = (
    // The list pane takes the plain keys of its rows; the search field forwards Up, Down and Return.
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/click-events-have-key-events -- the rows are the grid's; this only hears their keys and the empty area's menu and click.
    <div
      className="bm-list-pane"
      onKeyDown={listOnlyKeys}
      onContextMenu={(event) => openMenu(event, addItems())}
      onClick={(event) => {
        // A click on no row (below the last one) clears the selection.
        if (event.target instanceof Element && !event.target.closest(".bm-row")) store.select(undefined);
      }}
    >
      {layout === "two-pane" ? crumbs : null}
      {snap.notice && !down ? (
        <p className="bm-notice" role="alert">
          {snap.notice.message}
        </p>
      ) : null}
      {down && !downLasting ? null : down ? (
        <output className="bm-empty">
          <span className="bm-empty-title">{t("page.disconnected")}</span>
        </output>
      ) : empty ? (
        snap.loading ? null : (
          <div className="bm-empty">
            <span className="bm-empty-title">{t(searching ? "page.emptySearchTitle" : "page.emptyTitle")}</span>
            <span className="bm-empty-hint">{t(searching ? "page.emptySearchHint" : "page.emptyHint")}</span>
          </div>
        )
      ) : (
        <VirtualList
          id="bm-list"
          className="bm-list"
          role="grid"
          label={searching ? t("page.search") : (trail.at(-1)?.title ?? t("page.title"))}
          count={rows.length}
          estimateSize={() => ROW_HEIGHT[layout]}
          activeIndex={focusIndex >= 0 ? focusIndex : undefined}
          activeScrollKey={`${snap.folder}\0${snap.text}\0${snap.focus ?? ""}`}
          renderRow={(index, style) => {
            const node = rows[index];
            if (!node) return null;
            rendered.push(node);
            return (
              <BookmarkRow
                key={node.id}
                node={node}
                style={style}
                index={index}
                layout={layout}
                selected={snap.selection.includes(node.id)}
                focused={node.id === snap.focus}
                drop={dropMark?.id === node.id ? dropMark.kind : undefined}
                detail={
                  searching
                    ? folderPath(snap.tree, node.id, titles).join(PATH_SEPARATOR)
                    : node.url && layout !== "compact"
                      ? displayURL(node.url)
                      : ""
                }
                icon={snap.icons[iconKey(node)]}
                onClick={(event) => {
                  event.currentTarget.focus();
                  store.select(node.id, event.shiftKey ? "range" : event.metaKey ? "toggle" : "single");
                }}
                onOpen={() => store.activate(node)}
                onMenu={(event) => rowMenu(node, event)}
                onDragStart={(event) => dragStart(node, event)}
                onDragEnd={dragEnd}
                onDragOver={(event) => overRow(node, event)}
                onDragLeave={() => {
                  if (dropMark?.id === node.id) setDropMark(null);
                }}
                onDrop={(event) => dropRow(node, event)}
              />
            );
          }}
        />
      )}
    </div>
  );

  return (
    <div className={`bm-page is-${layout}`}>
      <header className="bm-header">
        <h1 className="bm-title">{t("page.title")}</h1>
        <input
          className="bm-search"
          type="search"
          placeholder={t("page.search")}
          aria-label={t("page.search")}
          aria-controls="bm-list"
          value={snap.text}
          disabled={down && downLasting}
          ref={focusOnMount}
          onChange={(event) => store.setText(event.target.value)}
          onKeyDown={searchKeys}
        />
        <button
          type="button"
          className="bm-more"
          aria-label={t("page.more")}
          title={t("page.more")}
          onClick={(event) => {
            const rect = event.currentTarget.getBoundingClientRect();
            setMenu({
              session: ++menuSession.current,
              x: rect.left,
              y: rect.bottom + 4,
              items: moreItems(),
              returnFocus: event.currentTarget,
            });
          }}
        >
          <MoreGlyph />
        </button>
      </header>
      {layout === "two-pane" ? null : crumbs}
      <div className="bm-body">
        {layout === "two-pane" ? (
          <FolderTree
            snap={snap}
            titles={titles}
            searching={searching}
            dropMark={dropMark}
            label={t("page.title")}
            onShow={(folder) => store.showFolder(folder)}
            onToggle={(folder, open) => store.setCollapsed(folder, !open)}
            onMenu={(node, event) => openMenu(event, nodeItems(node, [node.id]))}
            onDragOver={overFolder}
            onDragLeave={(folder) => {
              if (dropMark?.id === folder) setDropMark(null);
            }}
            onDrop={dropFolder}
          />
        ) : null}
        {list}
      </div>
      {snap.editor ? (
        <BookmarkEditor store={store} editor={snap.editor} tree={snap.tree} titles={titles} strings={strings} />
      ) : null}
      {menu && (
        <PageMenu
          key={menu.session}
          x={menu.x}
          y={menu.y}
          items={menu.items}
          returnFocus={menu.returnFocus}
          onClose={() => setMenu(null)}
        />
      )}
    </div>
  );
}

interface RowProps {
  node: Bookmark;
  style: React.CSSProperties;
  index: number;
  layout: BookmarksLayout;
  selected: boolean;
  focused: boolean;
  drop?: "before" | "into";
  detail: string;
  icon?: RowIcon | null;
  onClick: (event: MouseEvent<HTMLDivElement>) => void;
  onOpen: () => void;
  onMenu: (event: MouseEvent) => void;
  onDragStart: (event: DragEvent) => void;
  onDragEnd: () => void;
  onDragOver: (event: DragEvent) => void;
  onDragLeave: () => void;
  onDrop: (event: DragEvent) => void;
}

function BookmarkRow({ node, style, index, layout, selected, focused, drop, detail, icon, ...on }: RowProps) {
  const title = node.title || (node.url ? displayURL(node.url) : "");
  return (
    // A row of the multi-select grid: the grid pane takes its keys (Up/Down, Return, Delete).
    // oxlint-disable-next-line jsx-a11y/click-events-have-key-events -- the pane above handles the row's keys.
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized grid row: absolutely placed, no table layout.
      role="row"
      tabIndex={focused ? 0 : -1}
      aria-selected={selected}
      aria-rowindex={index + 1}
      data-bookmark={node.id}
      className={`bm-row${selected ? " selected" : ""}${drop ? ` drop-${drop}` : ""}`}
      style={style}
      title={layout === "compact" && node.url ? node.url : undefined}
      draggable
      onClick={on.onClick}
      onDoubleClick={on.onOpen}
      onContextMenu={on.onMenu}
      onDragStart={on.onDragStart}
      onDragEnd={on.onDragEnd}
      onDragOver={on.onDragOver}
      onDragLeave={on.onDragLeave}
      onDrop={on.onDrop}
    >
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the one cell of a virtualized grid row. */}
      <span className="bm-row-cell" role="gridcell">
        <BookmarkIcon node={node} icon={icon} />
        <span className="bm-row-title">{title}</span>
        {detail ? <span className="bm-row-detail">{detail}</span> : null}
      </span>
    </div>
  );
}

interface TreeProps {
  snap: BookmarksSnapshot;
  titles: RootTitles;
  searching: boolean;
  dropMark: DropMark;
  label: string;
  onShow: (folder: string) => void;
  onToggle: (folder: string, open: boolean) => void;
  onMenu: (node: Bookmark, event: MouseEvent) => void;
  onDragOver: (folder: string, event: DragEvent) => void;
  onDragLeave: (folder: string) => void;
  onDrop: (folder: string, event: DragEvent) => void;
}

/** The left folder tree (ui/Tree): the two roots and their folders, indented, each a drop target.
 * It lists folders only, the few a tree holds, so it draws every open one. */
function FolderTree({ snap, titles, searching, dropMark, label, ...on }: TreeProps) {
  const lines: TreeLine[] = treeRows(snap.tree, titles, snap.collapsed).map((row) => {
    const node = snap.tree.nodes.get(row.id);
    const expandable = hasSubfolders(snap.tree, row.id);
    const expanded = expandable && !snap.collapsed.has(row.id);
    return {
      kind: "item",
      key: row.id,
      depth: row.depth,
      text: row.title,
      expandable,
      expanded,
      content: (
        // The drop target and the menu of the row: the tree above owns its focus and keys.
        // oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- pointer-only drop target inside a treeitem.
        <span
          className={`bm-tree-cell${dropMark?.id === row.id ? " drop-into" : ""}`}
          onContextMenu={(event) => {
            if (node) on.onMenu(node, event);
          }}
          onDragOver={(event) => on.onDragOver(row.id, event)}
          onDragLeave={() => on.onDragLeave(row.id)}
          onDrop={(event) => on.onDrop(row.id, event)}
        >
          <span className={`bm-chevron${expandable ? "" : " is-leaf"}${expanded ? " is-open" : ""}`}>
            <ChevronGlyph />
          </span>
          <span className="bm-icon" aria-hidden="true">
            {isRoot(row.id) ? <BarGlyph root={row.id} /> : <FolderGlyph />}
          </span>
          <span className="bm-tree-title">{row.title}</span>
        </span>
      ),
    };
  });
  return (
    <nav className="bm-tree-pane" aria-label={label}>
      <Tree
        lines={lines}
        selected={searching ? undefined : snap.folder}
        label={label}
        autoFocus={false}
        className="bm-tree"
        rowClassName="bm-tree-row"
        rowStyle={(item) => ({ paddingInlineStart: 4 + item.depth * 16 })}
        onSelect={on.onShow}
        onExpand={on.onToggle}
        onActivate={(item) => on.onShow(item.key)}
      />
    </nav>
  );
}

/** A row's icon in a box the size of a favicon, reserved before the icon arrives (no pop-in shift). */
function BookmarkIcon({ node, icon }: { node: Bookmark; icon?: RowIcon | null }) {
  return (
    <span className="bm-icon" aria-hidden="true">
      {icon?.mask ? (
        <span className="bm-icon-mask" style={{ maskImage: `url("${icon.src}")` }} />
      ) : icon ? (
        <img src={icon.src} alt="" />
      ) : node.kind === "folder" ? (
        <FolderGlyph />
      ) : (
        <GlobeGlyph />
      )}
    </span>
  );
}

function FolderGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16">
      <path
        d="M1.75 4.25c0-.83.67-1.5 1.5-1.5h2.9l1.5 1.5h5.1c.83 0 1.5.67 1.5 1.5v6c0 .83-.67 1.5-1.5 1.5H3.25c-.83 0-1.5-.67-1.5-1.5z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function GlobeGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16">
      <g fill="none" stroke="currentColor" strokeWidth="1.1">
        <circle cx="8" cy="8" r="6.25" />
        <ellipse cx="8" cy="8" rx="2.6" ry="6.25" />
        <path d="M1.9 6h12.2M1.9 10h12.2" />
      </g>
    </svg>
  );
}

function BarGlyph({ root }: { root: string }) {
  return root === "bar" ? (
    <svg viewBox="0 0 16 16" width="16" height="16">
      <path
        d="M8 2.2l1.7 3.5 3.8.55-2.75 2.68.65 3.8L8 10.95l-3.4 1.78.65-3.8L2.5 6.25l3.8-.55z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.1"
        strokeLinejoin="round"
      />
    </svg>
  ) : (
    <FolderGlyph />
  );
}

function ChevronGlyph() {
  return (
    <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
      <path d="M4.5 3l3 3-3 3" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
    </svg>
  );
}

function MoreGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <g fill="currentColor">
        <circle cx="8" cy="3.5" r="1.3" />
        <circle cx="8" cy="8" r="1.3" />
        <circle cx="8" cy="12.5" r="1.3" />
      </g>
    </svg>
  );
}
