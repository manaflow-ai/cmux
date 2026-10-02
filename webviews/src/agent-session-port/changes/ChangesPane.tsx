// Codex "Changes" pane: scope picker, branch pill, toolbar, tracked-only banner, the
// stacked diffs (@pierre/diffs) and the changed-file tree (@pierre/trees).
//
// It renders (changes: ChangesSource, state: ChangesPaneState). State is either owned by
// the pane (`initial`, reduced with changesReducer) or by the app (`state` + `dispatch`).
// This file derives the view from those two and wires events to actions; the parts in
// parts/ are presentational.
import { useId, useReducer, useRef, useState, type CSSProperties } from "react";
import { Virtualizer } from "@pierre/diffs";
import { useStableCallback, VirtualizerContext } from "@pierre/diffs/react";
import { registerCodexDiffTheme } from "./theme";
import {
  HEADER_LABELS,
  LOAD_COPY,
  MANUAL_FRAME,
  SCOPE_ORDER,
  TOOLBAR_LABELS,
  trackedOnlyBanner,
} from "./constants";
import { changesReducer, initPaneState, isCollapsed, SCOPE_LABELS, totals } from "./model";
import type { ChangedFile, ChangesAction, ChangesPaneState, ToolbarButtonId } from "./model";
import type { ChangesPaneProps, MenuRow, PaneFrame } from "./types";
import { useOverlayThumb } from "./OverlayScrollbar";
import { usePaneReady } from "./usePaneReady";
import { BranchPill, ScopePill, Toolbar } from "./parts/Header";
import { Banner, LoadMessage } from "./parts/Banner";
import { DiffList, type FileHandlers, type FileView } from "./parts/DiffList";
import { ChangesTree } from "./parts/ChangesTree";
import { Menu, Tooltip } from "./parts/Overlays";
import { paneAnchors } from "./parts/TopLayer";
import "./changes.css";

export type { ChangesPaneProps } from "./types";
export { FileTypeIcon } from "./parts/FileTypeIcon";

registerCodexDiffTheme();

const NO_FILES: ChangedFile[] = [];

/**
 * Chromium paints an element whose left edge sits on a half CSS pixel at the next whole
 * pixel, even at 2x. Place the pane on the whole pixel and move it with a transform, which
 * is not snapped, so its 1px border lands on the captured half-pixel position.
 */
function snapFrame(f: PaneFrame): CSSProperties {
  const left = Math.floor(f.left);
  const top = Math.floor(f.top);
  const dx = f.left - left;
  const dy = f.top - top;
  return {
    left,
    top,
    width: f.width,
    height: f.height,
    transform: dx || dy ? `translate(${dx}px, ${dy}px)` : undefined,
  };
}

/** Pane state: the app's when it passes `state` + `dispatch`, otherwise the pane's own. */
function usePaneState({
  state,
  dispatch,
  initial,
  changes,
}: ChangesPaneProps): [ChangesPaneState, (a: ChangesAction) => void] {
  const own = useReducer(changesReducer, initial, (i) => initPaneState(i, changes));
  return state && dispatch ? [state, dispatch] : own;
}

export function ChangesPane(props: ChangesPaneProps) {
  const {
    changes,
    frame = MANUAL_FRAME,
    onReady,
    onRefresh,
    onOpenFile,
    className,
    style,
    virtualize,
  } = props;
  const [s, dispatch] = usePaneState(props);
  const anchors = paneAnchors(useId());
  const filterInput = useRef<HTMLInputElement>(null);

  // What the current scope shows.
  const load = changes[s.scope] ?? { status: "empty" as const };
  const changeSet = load.status === "loaded" ? load.changeSet : null;
  const files = changeSet?.files ?? NO_FILES;
  const paths = files.map((f) => f.path);
  const selectedPath = s.selectedPath ?? files[0]?.path ?? null;
  const banner = changeSet?.untrackedSkipped ? trackedOnlyBanner(changeSet.untrackedSkipped) : null;
  const branch =
    changeSet?.head && changeSet.base ? { head: changeSet.head, base: changeSet.base } : null;

  const ready = usePaneReady(paths, onReady);
  const { thumb: vThumb, attach: attachV, measure: measureV } = useOverlayThumb("y", 3, 3);

  // The diff list is a real scroller. The captured offset is state: apply it when the list
  // attaches and again after each diff paints, until the content is tall enough to hold it
  // (Pierre renders asynchronously, so the first attempt may clamp to 0).
  const diffs = useRef<HTMLDivElement | null>(null);
  const scrollApplied = useRef(false);
  const applyScroll = useStableCallback(() => {
    const el = diffs.current;
    if (!el || scrollApplied.current) return;
    el.scrollTop = s.scroll.diffTop;
    scrollApplied.current = Math.abs(el.scrollTop - s.scroll.diffTop) < 1;
  });
  // Stable identity, so React attaches it once instead of on every render.
  const diffsRef = useStableCallback((el: HTMLDivElement | null) => {
    diffs.current = el;
    applyScroll();
    attachV(el);
  });
  const scrollToFile = (path: string) => {
    const block = diffs.current?.querySelector<HTMLElement>(
      `.cx-file[data-path="${CSS.escape(path)}"]`,
    );
    if (block && diffs.current) diffs.current.scrollTop = block.offsetTop;
  };

  const refresh = () => onRefresh?.(s.scope);
  const copyPath = (path: string) => navigator.clipboard?.writeText(path);
  const pressTool = (id: ToolbarButtonId) => {
    switch (id) {
      case "options":
        return dispatch({ type: "toggleMenu", menu: { kind: "options" } });
      case "jump":
        if (!s.showTree) dispatch({ type: "toggle", flag: "showTree" });
        return filterInput.current?.focus();
      case "refresh":
        return refresh();
      case "wrap":
      case "split":
        return dispatch({ type: "toggle", flag: id });
      case "tree":
        return dispatch({ type: "toggle", flag: "showTree" });
      case "collapse":
        return dispatch({ type: "toggleCollapseAll", paths });
    }
  };
  const fileHandlers: FileHandlers = {
    hover: (path, button) => dispatch({ type: "hover", target: { kind: "file", path, button } }),
    leave: (path) =>
      s.hover?.kind === "file" &&
      s.hover.path === path &&
      dispatch({ type: "hover", target: null }),
    toggleCollapsed: (path) => dispatch({ type: "toggleCollapsed", path, paths }),
    press: (path, button) => {
      if (button === "viewed") dispatch({ type: "toggleViewed", path });
      else if (button === "actions") dispatch({ type: "toggleMenu", menu: { kind: "file", path } });
      else onOpenFile?.(path, button === "open-tab" ? "tab" : "editor");
    },
  };

  // Derived view state.
  const hover = s.hover;
  const fileView = (path: string): FileView => ({
    collapsed: isCollapsed(s, path),
    viewed: s.viewed.includes(path),
    hovered: hover?.kind === "file" && hover.path === path,
    hoveredButton: hover?.kind === "file" && hover.path === path ? hover.button : undefined,
    menuOpen: s.menu?.kind === "file" && s.menu.path === path,
    scrollLeft: s.scroll.diffLeft[path],
  });
  // The compact toolbar of a narrow pane is a container query on the pane (changes.css).
  const toolbar = {
    active: [s.showTree && "tree", s.wrap && "wrap", s.split && "split"].filter(
      Boolean,
    ) as ToolbarButtonId[],
    pressed: s.menu?.kind === "options" ? ("options" as const) : null,
    focused: s.focus,
    hovered: hover?.kind === "toolbar" ? hover.button : null,
    refreshing: load.status === "loading",
  };
  const fileIndex = (path: string) => paths.indexOf(path);
  const tooltip =
    hover?.kind === "toolbar"
      ? {
          text: TOOLBAR_LABELS[hover.button],
          anchor: anchors.tool(hover.button),
          side: "below" as const,
        }
      : hover?.kind === "file" &&
          hover.button &&
          hover.button !== "actions" &&
          fileIndex(hover.path) >= 0
        ? {
            text:
              hover.button === "viewed" && s.viewed.includes(hover.path)
                ? "Mark as unviewed"
                : HEADER_LABELS[hover.button],
            anchor: anchors.file(fileIndex(hover.path), hover.button),
            side: "above" as const,
          }
        : null;
  const menu = s.menu
    ? menuFor(s.menu, s, { dispatch, paths, refresh, copyPath, onOpenFile })
    : null;
  const menuAnchor =
    s.menu?.kind === "scope"
      ? anchors.scope
      : s.menu?.kind === "options"
        ? anchors.tool("options")
        : s.menu
          ? anchors.file(fileIndex(s.menu.path), "actions")
          : "";
  const message =
    load.status === "error"
      ? { ...LOAD_COPY.error, body: load.message ?? LOAD_COPY.error.body }
      : load.status === "empty"
        ? LOAD_COPY.empty
        : null;

  // Large change sets: one Pierre Virtualizer on the diff scroller renders only the files
  // and lines near the viewport. Its root is the scroller, its content the wrapper below.
  const [virtualizer] = useState(() => (virtualize ? new Virtualizer() : undefined));
  const virtualContentRef = useStableCallback((el: HTMLDivElement | null) => {
    if (!virtualizer) return;
    if (el?.parentElement) virtualizer.setup(el.parentElement, el);
    else virtualizer.cleanUp();
  });
  const diffList = (
    <DiffList
      files={files}
      fileView={fileView}
      display={{ wrap: s.wrap, split: s.split }}
      anchor={anchors.file}
      on={fileHandlers}
      onPainted={(path) => {
        applyScroll();
        measureV();
        ready.diffPainted(path);
      }}
      onHeaderMounted={ready.headerMounted}
    />
  );

  return (
    <div
      ref={ready.paneRef}
      className={`cx-changes${className ? ` ${className}` : ""}`}
      data-status={load.status}
      data-has-banner={banner ? "" : undefined}
      data-has-branch={branch ? "" : undefined}
      data-build={props.build ?? "manual"}
      style={{ ...snapFrame(frame), ...style }}
      onPointerLeave={() => hover && dispatch({ type: "hover", target: null })}
    >
      <div className="cx-pills">
        <ScopePill
          label={SCOPE_LABELS[s.scope]}
          counts={changeSet ? totals(changeSet) : null}
          open={s.menu?.kind === "scope"}
          anchor={anchors.scope}
          onToggle={() => dispatch({ type: "toggleMenu", menu: { kind: "scope" } })}
        />
        {branch && <BranchPill head={branch.head} base={branch.base} />}
      </div>
      <Toolbar
        view={toolbar}
        anchors={anchors}
        onPress={pressTool}
        onHover={(id) => dispatch({ type: "hover", target: id && { kind: "toolbar", button: id } })}
        onFocus={(id) => dispatch({ type: "focus", button: id })}
      />
      {banner && <Banner banner={banner} onRefresh={refresh} />}
      <div className="cx-body" data-tree={s.showTree ? "" : undefined}>
        <div className="cx-diffs" ref={diffsRef}>
          {message && <LoadMessage {...message} onAction={refresh} />}
          {virtualizer ? (
            <VirtualizerContext.Provider value={virtualizer}>
              <div className="cx-diffs-content" ref={virtualContentRef}>
                {diffList}
              </div>
            </VirtualizerContext.Provider>
          ) : (
            diffList
          )}
        </div>
        <div className="cx-vscroll">
          {vThumb && (
            <div className="cx-thumb" style={{ top: vThumb.offset, height: vThumb.length }} />
          )}
        </div>
        {s.showTree && (
          <div className="cx-tree">
            <ChangesTree
              // Pierre's tree model is created once: a new file list (another scope, or a
              // reload such as Retry after an error) mounts a new tree.
              key={`${s.scope}\n${files.map((f) => f.path).join("\n")}`}
              files={files}
              selectedPath={selectedPath}
              filter={s.filter}
              filterRef={filterInput}
              onFilter={(filter) => dispatch({ type: "setFilter", filter })}
              onSelect={(path) => {
                dispatch({ type: "selectFile", path });
                scrollToFile(path);
              }}
            />
          </div>
        )}
      </div>
      {menu && (
        <Menu
          rows={menu.rows}
          placement={menu.placement}
          anchor={menuAnchor}
          onClose={() => dispatch({ type: "closeMenu" })}
        />
      )}
      {tooltip && <Tooltip {...tooltip} />}
    </div>
  );
}

/** Rows of the open menu, each bound to the action it performs. */
function menuFor(
  menu: NonNullable<ChangesPaneState["menu"]>,
  s: ChangesPaneState,
  ctx: {
    dispatch: (a: ChangesAction) => void;
    paths: string[];
    refresh: () => void;
    copyPath: (path: string) => void;
    onOpenFile?: (path: string, where: "tab" | "editor") => void;
  },
): { placement: "scope" | "options" | "file"; rows: MenuRow[] } {
  const { dispatch, paths } = ctx;
  switch (menu.kind) {
    case "scope":
      return {
        placement: "scope",
        rows: SCOPE_ORDER.map((scope) =>
          scope === "-"
            ? "-"
            : {
                label: SCOPE_LABELS[scope],
                submenu: scope === "committed",
                checked: scope === s.scope,
                run: () => dispatch({ type: "selectScope", scope }),
              },
        ),
      };
    case "options":
      return {
        placement: "options",
        rows: [
          { label: "Refresh", icon: "refresh", run: ctx.refresh },
          {
            label: s.wrap ? "Disable word wrap" : "Word wrap",
            icon: "wrap",
            run: () => dispatch({ type: "toggle", flag: "wrap" }),
          },
          {
            label: s.split ? "Switch to unified diff" : "Switch to split diff",
            icon: "split",
            run: () => dispatch({ type: "toggle", flag: "split" }),
          },
          {
            label: "Collapse all diffs",
            icon: "collapse",
            run: () => dispatch({ type: "toggleCollapseAll", paths }),
          },
          "-",
          { label: "Load full files", icon: "file", checked: true },
          { label: "Rich preview", icon: "image" },
          { label: "Word diffs", icon: "plus-minus", checked: true },
          { label: "Hide white space", icon: "eye" },
          { label: "Hide imports", icon: "cube" },
          { label: "Copy git apply command", icon: "clipboard", disabled: paths.length === 0 },
        ],
      };
    case "file": {
      const path = menu.path;
      return {
        placement: "file",
        rows: [
          { label: "Copy path", run: () => ctx.copyPath(path) },
          { label: "Open file in a tab", run: () => ctx.onOpenFile?.(path, "tab") },
          {
            label: isCollapsed(s, path) ? "Expand file" : "Collapse file",
            run: () => dispatch({ type: "toggleCollapsed", path, paths }),
          },
        ],
      };
    }
  }
}
