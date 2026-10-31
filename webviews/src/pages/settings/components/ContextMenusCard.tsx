// Settings > Menus: every right-click menu, arranged by the person (Swift `ContextMenuLayout`,
// cmux.json `contextMenus`) as a tree, so any row goes anywhere at any depth. The list names each
// menu; the editor draws the chosen menu as its rows, each submenu's rows indented under it.
// - A row's grip drags it anywhere: before or after any row, into any submenu (menuDrag.ts).
// - Its buttons step it up or down, move it to any submenu (Move to…, also its right-click menu),
//   and hide or show it in place; a submenu of the person's renames and deletes.
// - New Submenu makes one of the person's; Add Separator adds one; Reset brings back the app's menu.
// Customize Menu… at the end of a menu opens this page on it (`?focus=<menu>`).
import { useId, useRef, useState, type KeyboardEvent, type MouseEvent, type PointerEvent } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { nativeMenu, pickedId } from "../../../ui/nativeMenu";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import { DRAG_THRESHOLD, INDENT, block, dropTarget, rowBoxes, shifts, type DropTarget, type RowBox } from "../menuDrag";
import {
  MORE,
  SEPARATOR,
  addGroup,
  addSeparator,
  deleteGroup,
  destinations,
  isFolder,
  isGenerated,
  isGroup,
  keyOf,
  move,
  moveInto,
  nodeAt,
  removeSeparator,
  renameGroup,
  sameLayout,
  samePath,
  step,
  toggleHidden,
  visibleRows,
  within,
  type Folder,
  type Path,
  type VisibleRow,
} from "../menuLayouts";
import type { ContextMenuState, MenuLayout, MenuNode, MenuRow } from "../ops";
import { sectionHref } from "../router";
import { t } from "../strings";
import { ResetSpacer } from "./ResetButton";

const AREAS = ["workspace", "tabs", "terminal", "browser", "other"] as const;

/** A press on a grip: a drag once the pointer travels `DRAG_THRESHOLD`; the rows as they stood
 * when it began, the dragged block, and where it would drop. */
type Dragging = {
  path: Path;
  depth: number;
  startX: number;
  startY: number;
  dy: number;
  active: boolean;
  rows: RowBox[];
  first: number;
  last: number;
  height: number;
  target: DropTarget | null;
  /** How far each other row slides, by its drawn index. */
  slide: Map<number, number>;
  /** The layout the drag began on: a drop onto a layout that changed under it does nothing. */
  layout: MenuLayout;
};

const pathKey = (path: Path) => path.join(".");

function newID(): string {
  return globalThis.crypto?.randomUUID?.().slice(0, 8) ?? Math.random().toString(36).slice(2, 10);
}

/** A row's SF Symbol (`symbol/<name>`, a template PNG) inked like the row's text: the image is an
 * alpha mask over a `currentColor` rect, as a macOS menu draws its template icons. */
function RowIcon({ symbol }: { symbol: string | null }) {
  // useId's characters (colons, guillemets) do not survive a `url(#…)` reference.
  const mask = `menu-icon-${useId().replace(/[^A-Za-z0-9_-]/g, "")}`;
  if (!symbol) return <span className="menu-row-icon" aria-hidden="true" />;
  const href = `symbol/${encodeURIComponent(encodeURIComponent(symbol))}`;
  return (
    <svg className="menu-row-icon" data-symbol={symbol} viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <mask id={mask} style={{ maskType: "alpha" }}>
        <image href={href} width="16" height="16" preserveAspectRatio="xMidYMid meet" />
      </mask>
      <rect width="16" height="16" fill="currentColor" mask={`url(#${mask})`} />
    </svg>
  );
}

/** A row's button: its tooltip names the action only; its accessible name adds the row. */
function ActionButton({
  icon,
  action,
  row,
  onClick,
  disabled = false,
  iconClass,
  data,
}: {
  icon: string;
  action: string;
  row?: string;
  onClick: (event: MouseEvent<HTMLButtonElement>) => void;
  disabled?: boolean;
  iconClass?: string;
  data?: string;
}) {
  return (
    <button
      type="button"
      className="icon-button"
      aria-label={row ? `${action}: ${row}` : action}
      title={action}
      disabled={disabled}
      data-action={data}
      onClick={onClick}
    >
      <Icon name={icon} className={iconClass} />
    </button>
  );
}

export function ContextMenusCard({ focus }: { focus: string | null }) {
  const store = useStore();
  const state = useSettingsState().host?.context_menus;
  const router = useSettingsRouter();
  const toggleId = useId();
  // The layout just saved, shown until the host lists bring it back, and the last write's refusal.
  const [pending, setPending] = useState<{ menu: string; layout: MenuLayout } | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [open, setOpen] = useState<ReadonlySet<string>>(() => new Set([MORE]));
  const [dragging, setDragging] = useState<Dragging | null>(null);
  const [renaming, setRenaming] = useState<{ key: string; title: string } | null>(null);
  // Move to… without the app's menu (the dev server, tests): the page draws the list.
  const [picker, setPicker] = useState<{ path: Path } | null>(null);
  const list = useRef<HTMLOListElement>(null);
  // The drag as the pointer events see it, ahead of React's render: a release that follows a move
  // before that move rendered drops where the pointer is, not where the last render had it.
  const drag = useRef<Dragging | null>(null);
  const renameDone = useRef(false);
  if (!state || state.menus.length === 0) return null;

  // The chosen menu is the route's focus: Customize Menu… opens `?focus=<menu>`, and picking a menu
  // here replaces it, so a later Customize Menu… always changes the route and selects its menu.
  const menu = state.menus.find((item) => item.id === focus) ?? state.menus[0]!;
  const layout = pending?.menu === menu.id ? pending.layout : menu.layout;
  const rowsByKey = new Map(menu.rows.map((row) => [row.key, row]));
  const shown = visibleRows(layout, open);
  const generated = isGenerated(menu, layout);

  const titleOf = (node: MenuNode): string => {
    if (node === SEPARATOR) return t("settingsWindow.menus.separator");
    if (isFolder(node) && isGroup(node.key)) return node.title ?? "";
    return rowsByKey.get(keyOf(node))?.title ?? keyOf(node);
  };
  const rowOf = (node: MenuNode): MenuRow | undefined => (node === SEPARATOR ? undefined : rowsByKey.get(keyOf(node)));
  const siblingsOf = (path: Path): MenuNode[] =>
    path.length === 1 ? layout.items : (nodeAt(layout.items, path.slice(0, -1)) as Folder).items;

  const save = (next: MenuLayout) => {
    const write = { menu: menu.id, layout: next };
    setPending(write);
    setFailure(null);
    store
      .setContextMenuLayout(menu.id, isGenerated(menu, next) ? null : next)
      .catch((error: unknown) => setFailure(error instanceof Error ? error.message : String(error)))
      .finally(() => setPending((current) => (current === write ? null : current)));
  };
  const openFolder = (key: string) => setOpen((current) => new Set([...current, key]));
  const toggleOpen = (key: string) =>
    setOpen((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  const folderKeys = (nodes: MenuNode[]): string[] =>
    nodes.flatMap((node) => (isFolder(node) ? [node.key, ...folderKeys(node.items)] : []));
  const allOpen = folderKeys(layout.items).every((key) => open.has(key));

  /** Where the node at `path` can move: the top level, then every submenu, as menu rows. */
  const moveChoices = (path: Path) => {
    const parent = path.slice(0, -1);
    return destinations(layout, path, (node: Folder) => titleOf(node)).map((destination) => ({
      id: `move:${pathKey(destination.path)}`,
      label: destination.trail.length === 0 ? t("settingsWindow.menus.topLevel") : destination.trail.join(" › "),
      current: samePath(destination.path, parent),
      run: () => {
        save(moveInto(layout, path, destination.path));
        const into = nodeAt(layout.items, destination.path);
        if (into) openFolder(keyOf(into));
      },
    }));
  };
  /** Move to…: the app's own menu at the button, else the page's list. */
  const openMoveTo = (path: Path, button: HTMLElement) => {
    const choices = moveChoices(path);
    const host = nativeMenu();
    if (!host) return setPicker({ path });
    const rect = button.getBoundingClientRect();
    void host({
      items: choices.map((choice) => ({
        id: choice.id,
        label: choice.label,
        ...(choice.current ? { disabled: true } : {}),
      })),
      point: { x: rect.left, y: rect.bottom },
    })
      .then((reply) => choices.find((choice) => choice.id === pickedId(reply))?.run())
      .catch(() => setPicker({ path }));
  };

  // MARK: Dragging

  const setDrag = (next: Dragging | null) => {
    drag.current = next;
    setDragging(next);
  };
  /** The drag after the pointer moved to (`x`, `y`): it starts past `DRAG_THRESHOLD`, measuring the
   * rows once, before any row slides (a slid row would move the target under the pointer). */
  const follow = (current: Dragging, x: number, y: number): Dragging => {
    const dy = y - current.startY;
    const element = list.current;
    if ((!current.active && Math.abs(dy) < DRAG_THRESHOLD) || !element) return current;
    const rows = current.active ? current.rows : rowBoxes(element);
    const { first, last } = current.active ? current : block(rows, current.path);
    // jsdom has no layout: a row is 24 px there, as the page draws it.
    const measured = (rows[last]?.bottom ?? 0) - (rows[first]?.top ?? 0);
    const height = current.active ? current.height : measured > 0 ? measured : 24 * (last - first + 1);
    const target = dropTarget(rows, current.path, height, y, x - current.startX);
    const slide = shifts(rows, first, last, height, target ? target.slot : undefined);
    return { ...current, dy, active: true, rows, first, last, height, target, slide };
  };
  const grip = (path: Path, depth: number) => ({
    onPointerDown: (event: PointerEvent<HTMLElement>) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.currentTarget.setPointerCapture?.(event.pointerId);
      setDrag({
        path,
        depth,
        startX: event.clientX,
        startY: event.clientY,
        dy: 0,
        active: false,
        rows: [],
        first: 0,
        last: 0,
        height: 0,
        target: null,
        slide: new Map(),
        layout,
      });
    },
    onPointerMove: (event: PointerEvent<HTMLElement>) => {
      const current = drag.current;
      if (!current || !samePath(current.path, path)) return;
      const next = follow(current, event.clientX, event.clientY);
      if (next !== current) setDrag(next);
    },
    onPointerUp: (event: PointerEvent<HTMLElement>) => {
      const current = drag.current;
      setDrag(null);
      if (!current || !samePath(current.path, path)) return;
      // Where the release is, not where the last render was.
      const done = follow(current, event.clientX, event.clientY);
      // The menu changed mid-drag (another window, a cmux.json edit): the paths measured at the
      // start may name other rows now, so nothing moves. An equal menu re-sent is no change.
      if (!done.active || !done.target || !sameLayout(done.layout, layout)) return;
      save(move(layout, done.path, done.target.parent, done.target.index));
      const into = done.target.into && nodeAt(layout.items, done.target.into);
      if (into) openFolder(keyOf(into));
    },
    onPointerCancel: () => setDrag(null),
  });
  /** A dragged row (and what an open submenu shows under it) follows the pointer, moving sideways
   * to the depth it will land at; the rows it passes slide to open the gap. Transforms only. */
  const lifted = (row: VisibleRow, flat: number) => {
    if (!dragging?.active) return undefined;
    if (within(row.path, dragging.path)) {
      const dx = dragging.target ? (dragging.target.depth - dragging.depth) * INDENT : 0;
      return { transform: `translate(${dx}px, ${dragging.dy}px)` };
    }
    const by = dragging.slide.get(flat);
    return by ? { transform: `translateY(${by}px)` } : undefined;
  };

  // MARK: Rows

  /** Saves the name field's title on the submenu it names (found by key, wherever it is now),
   * once: Enter commits and unmounts the field, whose blur then does nothing. */
  const commitRename = () => {
    if (!renaming || renameDone.current) return;
    renameDone.current = true;
    const title = renaming.title.trim();
    setRenaming(null);
    const at = visibleRows(layout, new Set(folderKeys(layout.items))).find(
      (row) => keyOf(row.node) === renaming.key,
    )?.path;
    if (title && at) save(renameGroup(layout, at, title));
  };
  const startRename = (key: string, title: string) => {
    renameDone.current = false;
    setRenaming({ key, title });
  };

  const rowMenuItems = (path: Path, node: MenuNode, hidden: boolean): ContextMenuItem[] => {
    const at = path[path.length - 1]!;
    const items: ContextMenuItem[] = [
      { id: "up", label: t("settingsPage.moveUp"), disabled: at === 0, onSelect: () => save(step(layout, path, -1)) },
      {
        id: "down",
        label: t("settingsPage.moveDown"),
        disabled: at === siblingsOf(path).length - 1,
        onSelect: () => save(step(layout, path, 1)),
      },
    ];
    moveChoices(path).forEach((choice, index) =>
      items.push({
        id: choice.id,
        label: `${t("settingsWindow.menus.moveTo")} ${choice.label}`,
        disabled: choice.current,
        separatorBefore: index === 0,
        onSelect: choice.run,
      }),
    );
    if (node === SEPARATOR) {
      items.push({
        id: "remove",
        label: t("settingsWindow.menus.removeSeparator"),
        separatorBefore: true,
        onSelect: () => save(removeSeparator(layout, path)),
      });
    } else if (isFolder(node) && isGroup(node.key)) {
      items.push(
        {
          id: "rename",
          label: t("settingsWindow.menus.rename"),
          separatorBefore: true,
          onSelect: () => startRename(node.key, node.title ?? ""),
        },
        {
          id: "delete",
          label: t("settingsWindow.menus.deleteSubmenu"),
          destructive: true,
          onSelect: () => save(deleteGroup(layout, path)),
        },
      );
    } else {
      items.push({
        id: "hide",
        label: hidden ? t("settingsWindow.menus.show") : t("settingsWindow.menus.hide"),
        separatorBefore: true,
        onSelect: () => save(toggleHidden(layout, keyOf(node))),
      });
    }
    return items;
  };

  const drawRow = (row: VisibleRow, flat: number) => {
    const { node, path, depth } = row;
    const key = keyOf(node);
    const id = pathKey(path);
    const folder = isFolder(node);
    const group = folder && isGroup(node.key);
    const info = rowOf(node);
    const title = titleOf(node);
    const expanded = folder && open.has(key);
    const at = path[path.length - 1]!;
    const last = siblingsOf(path).length - 1;
    const into = dragging?.active && dragging.target?.into && samePath(dragging.target.into, path);
    const dimmed = row.hidden || row.parentHidden;
    const style = { paddingInlineStart: `${2 + depth * INDENT}px`, ...lifted(row, flat) };
    const buttons = (
      <span className="menu-row-actions">
        <ActionButton
          icon="chevron"
          iconClass="icon-up"
          action={t("settingsPage.moveUp")}
          row={title}
          disabled={at === 0}
          onClick={() => save(step(layout, path, -1))}
        />
        <ActionButton
          icon="chevron"
          action={t("settingsPage.moveDown")}
          row={title}
          disabled={at === last}
          onClick={() => save(step(layout, path, 1))}
        />
        <ActionButton
          icon="arrow.turn.down.right"
          action={t("settingsWindow.menus.moveTo")}
          row={title}
          data="move-to"
          onClick={(event) => openMoveTo(path, event.currentTarget)}
        />
        {node === SEPARATOR ? (
          <ActionButton
            icon="xmark"
            action={t("settingsWindow.menus.removeSeparator")}
            data="remove"
            onClick={() => save(removeSeparator(layout, path))}
          />
        ) : group ? (
          <>
            <ActionButton
              icon="square.and.pencil"
              action={t("settingsWindow.menus.rename")}
              row={title}
              data="rename"
              onClick={() => startRename(key, node.title ?? "")}
            />
            <ActionButton
              icon="xmark"
              action={t("settingsWindow.menus.deleteSubmenu")}
              row={title}
              data="delete"
              onClick={() => save(deleteGroup(layout, path))}
            />
          </>
        ) : (
          <ActionButton
            icon={row.hidden ? "eye" : "eye.slash"}
            action={row.hidden ? t("settingsWindow.menus.show") : t("settingsWindow.menus.hide")}
            row={title}
            data="hide"
            onClick={() => save(toggleHidden(layout, key))}
          />
        )}
      </span>
    );
    const titleView =
      renaming && renaming.key === key && group ? (
        <input
          className="field menu-rename"
          aria-label={t("settingsWindow.menus.submenuName")}
          value={renaming.title}
          // oxlint-disable-next-line jsx-a11y/no-autofocus -- the field opens on the person's Rename, so focus goes to it.
          autoFocus
          onChange={(event) => setRenaming({ key, title: event.currentTarget.value })}
          onBlur={commitRename}
          onKeyDown={(event: KeyboardEvent<HTMLInputElement>) => {
            if (event.key === "Enter") commitRename();
            if (event.key === "Escape") {
              renameDone.current = true;
              setRenaming(null);
            }
          }}
        />
      ) : folder ? (
        <button
          type="button"
          className="menu-row-title menu-disclosure"
          aria-expanded={expanded}
          onClick={() => toggleOpen(key)}
        >
          <Icon name="chevron" className={expanded ? "menu-twisty" : "menu-twisty menu-twisty-closed"} />
          {title}
        </button>
      ) : (
        <span className="menu-row-title">{title}</span>
      );
    return (
      <li
        key={id}
        className={node === SEPARATOR ? "menu-row menu-separator" : "menu-row"}
        data-flat={flat}
        data-path={id}
        data-depth={depth}
        data-key={node === SEPARATOR ? undefined : key}
        data-folder={folder ? "" : undefined}
        data-open={expanded ? "" : undefined}
        data-children={folder ? node.items.length : undefined}
        data-hidden={dimmed ? "" : undefined}
        data-dragging={dragging?.active && within(path, dragging.path) ? "" : undefined}
        data-drop-into={into ? "" : undefined}
        style={style}
      >
        <ContextMenu className="menu-row-body" items={rowMenuItems(path, node, row.hidden)}>
          <span className="menu-row-grip" aria-hidden="true" {...grip(path, depth)}>
            <Icon name="grip" />
          </span>
          {node === SEPARATOR ? (
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the divider is drawn inside the draggable row's flex body beside its grip; an <hr> brings its own box.
            <span className="menu-separator-line" aria-label={title} role="separator" />
          ) : (
            <>
              {group ? (
                <span className="menu-row-icon" aria-hidden="true" />
              ) : (
                <RowIcon symbol={info?.symbol ?? null} />
              )}
              {titleView}
              {info?.kind === "submenu" ? (
                <span className="menu-row-chevron" aria-hidden="true">
                  ›
                </span>
              ) : null}
              {folder && node.items.length === 0 ? (
                <span className="menu-row-badge">{t("settingsWindow.menus.emptyFolder")}</span>
              ) : null}
              {row.hidden ? <span className="menu-row-badge">{t("settingsWindow.menus.hidden")}</span> : null}
            </>
          )}
          {buttons}
        </ContextMenu>
      </li>
    );
  };

  const areaTitle = (area: string) => t(`settingsWindow.menus.area.${area}`);

  return (
    <>
      <section className="group" data-card="context-menus-options">
        <div className="rows">
          <div className="row" tabIndex={-1}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title" id={toggleId}>
                  {t("settingsWindow.menus.customizeItem.title")}
                </div>
                <div className="row-help">{t("settingsWindow.menus.customizeItem.help")}</div>
              </div>
              <div className="row-control">
                <Switch
                  checked={state.show_customize_item}
                  disabled={false}
                  labelId={toggleId}
                  onToggle={(next) => {
                    setFailure(null);
                    store
                      .setShowCustomizeMenuItem(next)
                      .catch((error: unknown) => setFailure(error instanceof Error ? error.message : String(error)));
                  }}
                />
                <ResetSpacer />
              </div>
            </div>
          </div>
        </div>
      </section>
      <section className="group menus-editor" data-card="context-menus" data-menu={menu.id}>
        <nav className="menus-list" aria-label={t("settingsWindow.menus.listLabel")}>
          {AREAS.map((area) => {
            const menus = state.menus.filter((item) => item.area === area);
            if (menus.length === 0) return null;
            return (
              <div key={area} className="menus-area">
                <div className="menus-area-title">{areaTitle(area)}</div>
                {menus.map((item: ContextMenuState) => (
                  <button
                    key={item.id}
                    type="button"
                    className="menus-list-item"
                    data-menu={item.id}
                    aria-current={item.id === menu.id ? "true" : undefined}
                    onClick={() => router.history.replace(sectionHref("menus", item.id))}
                  >
                    <span>{item.title}</span>
                    {item.customized ? (
                      <span className="menus-edited" title={t("settingsWindow.menus.edited")} />
                    ) : null}
                  </button>
                ))}
              </div>
            );
          })}
        </nav>
        <div className="menus-detail">
          <header className="menus-detail-header">
            <h3 className="menus-detail-title">{menu.title}</h3>
            <span className="menus-detail-spacer" />
            <button
              type="button"
              className="button"
              data-action="expand"
              onClick={() => setOpen(allOpen ? new Set() : new Set(folderKeys(layout.items)))}
            >
              {allOpen ? t("settingsWindow.menus.collapseAll") : t("settingsWindow.menus.expandAll")}
            </button>
            <button
              type="button"
              className="button"
              data-action="new-submenu"
              onClick={() => {
                const made = addGroup(layout, t("settingsWindow.menus.newSubmenu"), newID());
                save(made.layout);
                startRename(made.key, t("settingsWindow.menus.newSubmenu"));
              }}
            >
              {t("settingsWindow.menus.newSubmenu")}
            </button>
            <button
              type="button"
              className="button"
              data-action="add-separator"
              onClick={() => save(addSeparator(layout))}
            >
              {t("settingsWindow.menus.addSeparator")}
            </button>
            <button
              type="button"
              className="button"
              data-action="reset"
              disabled={generated}
              onClick={() => save(menu.generated)}
            >
              {t("settingsWindow.menus.reset")}
            </button>
          </header>
          <p className="row-help menus-help">{t("settingsWindow.menus.help")}</p>
          {failure ? (
            <p className="menus-failure" role="alert" data-failure="">
              {failure}
            </p>
          ) : null}
          <ol
            className="menu-preview"
            data-menu-preview=""
            data-reordering={dragging?.active ? "" : undefined}
            ref={list}
          >
            {shown.map((row, flat) => drawRow(row, flat))}
          </ol>
          {picker ? (
            <div className="menus-move-picker" role="menu" aria-label={t("settingsWindow.menus.moveTo")} data-picker="">
              {moveChoices(picker.path).map((choice) => (
                <button
                  key={choice.id}
                  type="button"
                  role="menuitem"
                  className="menus-list-item"
                  data-destination={choice.id}
                  disabled={choice.current}
                  onClick={() => {
                    setPicker(null);
                    choice.run();
                  }}
                >
                  {choice.label}
                </button>
              ))}
              <button type="button" className="button" data-action="cancel-move" onClick={() => setPicker(null)}>
                {t("settingsWindow.menus.cancel")}
              </button>
            </div>
          ) : null}
        </div>
      </section>
    </>
  );
}
