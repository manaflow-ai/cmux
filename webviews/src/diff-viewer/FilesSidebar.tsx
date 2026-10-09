// Owns the files sidebar: its backdrop, the filtered file tree source, the Pierre file tree,
// its selection and filter focus, and the tree row decorations.
import { FileTree, useFileTree } from "@pierre/trees/react";
import { preparePresortedFileTreeInput } from "@pierre/trees";
import { useCallback, useEffect, useRef, useState } from "react";
import { type SidebarCommentEntry } from "../comments/annotations";
import { CommentsSidebarSection } from "../comments/CommentsSection";
import { type DiffCommentLabels } from "../comments/labels";
import { type DiffItem, type FileTreeSource } from "../diff-stream";
import { treeFileRowPath } from "../file-activation";
import { defaultDiffFileFilter, isDiffFileFilterActive, type DiffFileFilter } from "../file-filter";
import { planPierreFileTreeRefresh, selectPierreFileTreePath } from "../file-tree-refresh";
import { createTextMeasure, diffStatSpriteSheet, fileTreeStatsDecoration, type FileTreeStatsDecoration, type MeasureText } from "../file-tree-stats";
import { Icon } from "../icons";
import { fileTreeUnsafeCSS } from "../pierre-options";
import { type ViewedFileState } from "../viewed-files";
import type { DiffViewerLabelResolver } from "../labels";
import { type AppAction, type AppState } from "./state";
import { LoadingFileList } from "./Loading";
import { useSyncedRef } from "./useSyncedRef";

export function FilesSidebarBackdrop({
  label,
  onClose,
  open,
}: {
  label: DiffViewerLabelResolver;
  onClose: () => void;
  open: boolean;
}) {
  if (!open) {
    return null;
  }
  return (
    <button
      id="files-sidebar-backdrop"
      type="button"
      aria-controls="files-sidebar"
      aria-label={label("hideFileSearch")}
      title={label("hideFileSearch")}
      onClick={onClose}
    />
  );
}

/**
 * The tree source narrowed to the visible (filtered) items. With no active
 * filter the streamed source passes through unchanged so incremental tree
 * appends keep working; a filtered source resets the tree instead.
 */
export function filteredFileTreeSource(
  source: FileTreeSource | null,
  filter: DiffFileFilter,
  visibleItems: readonly DiffItem[],
): FileTreeSource | null {
  if (source == null || !isDiffFileFilterActive(filter)) {
    return source;
  }
  const visibleIds = new Set(visibleItems.map((item) => item.id));
  const paths = source.paths.filter((path) => {
    const itemId = source.pathToItemId.get(path);
    return itemId != null && visibleIds.has(itemId);
  });
  const pathSet = new Set(paths);
  return {
    ...source,
    gitStatus: source.gitStatus.filter((entry) => pathSet.has(entry.path)),
    gitStatusPatch: undefined,
    pathCount: paths.length,
    paths,
    previousRevision: undefined,
    previousSource: undefined,
    statsChanged: true,
  };
}

export function FilesSidebar({
  commentEntries,
  commentLabels,
  dispatch,
  hasDraft,
  label,
  onActivateItem,
  onSelectComment,
  onSelectItem,
  onToggleViewedPath,
  selectedPath,
  state,
  treeSource,
  viewedStateOf,
  visibleItemCount,
}: {
  commentEntries: SidebarCommentEntry[];
  commentLabels: DiffCommentLabels;
  dispatch: React.Dispatch<AppAction>;
  hasDraft: boolean;
  label: DiffViewerLabelResolver;
  onActivateItem: (itemId: string) => void;
  onSelectComment: (entry: SidebarCommentEntry) => void;
  onSelectItem: (itemId: string) => void;
  onToggleViewedPath: (path: string) => void;
  selectedPath: string;
  state: AppState;
  treeSource: FileTreeSource | null;
  viewedStateOf: (item: DiffItem) => ViewedFileState;
  visibleItemCount: number;
}) {
  const filter = state.fileFilter;
  const filterActive = isDiffFileFilterActive(filter);
  useFileFilterFocus(state.fileSearchOpen, state.fileSearchRequest);
  // Viewed marks by tree path so the tree row decorations can look them up.
  const viewedStateByPath = new Map<string, ViewedFileState>();
  for (const item of state.items) {
    const treePath = state.treeSource?.treePathByItemId.get(item.id);
    if (treePath != null) {
      viewedStateByPath.set(treePath, viewedStateOf(item));
    }
  }
  const dragStart = useRef<{ startWidth: number; startX: number } | null>(null);
  const resizeFiles = (clientX: number) => {
    const start = dragStart.current;
    if (!start) {
      return;
    }
    const viewportWidth = document.documentElement.clientWidth || window.innerWidth;
    const maximumWidth = Math.max(220, Math.min(520, Math.floor(viewportWidth * 0.55)));
    const nextWidth = Math.max(180, Math.min(maximumWidth, Math.round(start.startWidth - (clientX - start.startX))));
    dispatch({ type: "set-files-width", width: nextWidth });
  };
  return (
    <aside
      id="files-sidebar"
      aria-label={label("changedFiles")}
      // The streamed file count (the sidebar no longer shows a "Files N" title).
      data-file-count={state.treeSource?.pathCount ?? 0}
      aria-hidden={!state.filesVisible}
      inert={!state.filesVisible}
    >
      <button
        id="files-resize-handle"
        aria-label={label("files")}
        type="button"
        tabIndex={0}
        onPointerDown={(event) => {
          dragStart.current = { startWidth: state.filesWidth, startX: event.clientX };
          event.currentTarget.setPointerCapture(event.pointerId);
        }}
        onPointerMove={(event) => resizeFiles(event.clientX)}
        onPointerUp={(event) => {
          resizeFiles(event.clientX);
          dragStart.current = null;
          event.currentTarget.releasePointerCapture(event.pointerId);
        }}
        onPointerCancel={() => {
          dragStart.current = null;
        }}
        onKeyDown={(event) => {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
            return;
          }
          event.preventDefault();
          const delta = event.key === "ArrowLeft" ? 20 : -20;
          dispatch({ type: "set-files-width", width: Math.max(180, Math.min(520, state.filesWidth + delta)) });
        }}
      />
      {/* The sidebar is the filter field and the tree, nothing else (Lawrence,
          round 2). "Hide viewed files" lives in the "..." menu. */}
      <div id="files-filter" data-filter-active={filterActive}>
        <Icon name="search" />
        <input
          id="file-filter-input"
          type="search"
          value={filter.query}
          placeholder={label("filterFiles")}
          aria-label={label("filterFiles")}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => dispatch({ type: "set-file-filter", filter: { query: event.currentTarget.value } })}
        />
        {filterActive ? (
          <button
            id="file-filter-clear"
            type="button"
            className="files-filter-button"
            title={label("clearFileFilter")}
            aria-label={label("clearFileFilter")}
            onClick={() => dispatch({ type: "set-file-filter", filter: defaultDiffFileFilter() })}
          >
            <Icon name="close" />
          </button>
        ) : null}
      </div>
      <div id="file-list">
        {treeSource && (visibleItemCount > 0 || !filterActive) ? (
          <PierreFileTree
            label={label}
            onActivateItem={onActivateItem}
            onSelectItem={onSelectItem}
            onToggleViewedPath={onToggleViewedPath}
            selectedPath={selectedPath}
            source={treeSource}
            viewedStateByPath={viewedStateByPath}
          />
        ) : treeSource && filterActive ? (
          <div id="files-filter-empty">{label("noFilesMatchFilter")}</div>
        ) : state.status.loading || state.status.pending ? (
          <LoadingFileList />
        ) : (
          <div className="visually-hidden">{state.status.message}</div>
        )}
      </div>
      <CommentsSidebarSection
        entries={commentEntries}
        hasDraft={hasDraft}
        labels={commentLabels}
        onSelect={onSelectComment}
      />
    </aside>
  );
}

function PierreFileTree({
  label,
  onActivateItem,
  onSelectItem,
  onToggleViewedPath,
  selectedPath,
  source,
  viewedStateByPath,
}: {
  label: DiffViewerLabelResolver;
  /** A plain click (or Enter/Space) on a file row: the shared file activation. */
  onActivateItem: (itemId: string) => void;
  /** A selection the tree made some other way (arrow keys): scroll to the file. */
  onSelectItem: (itemId: string) => void;
  onToggleViewedPath: (path: string) => void;
  selectedPath: string;
  source: FileTreeSource;
  viewedStateByPath: ReadonlyMap<string, ViewedFileState>;
}) {
  const latest = useSyncedRef({ label, onSelectItem, selectedPath, source, viewedStateByPath });
  // Set by a file row click in the capture phase, before the tree selects the
  // row, and cleared when the click finishes bubbling.
  const activatedPath = useRef<string | null>(null);
  const syncingSelection = useRef(false);
  const onActivate = useSyncedRef(onActivateItem);
  // Native listeners (not JSX handlers): the wrapper is not itself a control,
  // the row buttons are, and keyboard activation reaches it as their click.
  const treeActivationRef = useCallback(
    (element: HTMLDivElement | null) => {
      if (element == null) {
        return;
      }
      const capture = (event: MouseEvent) => {
        activatedPath.current = null;
        const path = treeFileRowPath(event);
        const itemId = path == null ? undefined : latest.current.source.pathToItemId.get(path);
        if (path != null && itemId != null) {
          activatedPath.current = path;
          onActivate.current(itemId);
        }
      };
      const finish = () => {
        activatedPath.current = null;
      };
      element.addEventListener("click", capture, true);
      element.addEventListener("click", finish);
      return () => {
        element.removeEventListener("click", capture, true);
        element.removeEventListener("click", finish);
      };
    },
    [latest, onActivate],
  );
  const [initialPreparedInput] = useState(() => preparePresortedFileTreeInput(source.paths));
  const [measureStats] = useState(() => createTextMeasure(FILE_TREE_FONT_FAMILY));
  const { model } = useFileTree({
    // Single-child folder chains render as one row ("infra / tsadmin").
    flattenEmptyDirectories: true,
    id: "cmux-diff-file-tree",
    initialExpansion: "open",
    initialSelectedPaths: selectedPath ? [selectedPath] : [],
    initialVisibleRowCount: getInitialFileTreeRowCount(),
    // The sidebar's own filter field (FilesSidebar) is the one search; the
    // rows are the classic viewer's 29 px (screenshot 5.20.26).
    itemHeight: FILE_TREE_ITEM_HEIGHT,
    overscan: 12,
    preparedInput: initialPreparedInput,
    search: false,
    stickyFolders: true,
    // No `gitStatus`: the classic list shows no status letters, changed-folder
    // dots or status-colored names, only the counts.
    icons: fileTreeIcons(source.statsByPath.values(), measureStats),
    sort: () => 0,
    unsafeCSS: fileTreeUnsafeCSS(),
    composition: { contextMenu: { enabled: true, triggerMode: "right-click" } },
    // "+N -N" in green and red (file-tree-stats.ts). Viewed marks stay on the
    // file bar's eye and the row's context menu.
    renderRowDecoration({ item }) {
      return fileTreeRowDecoration(
        latest.current.source.statsByPath.get(item.path),
        latest.current.label,
        measureStats,
      );
    },
    onSelectionChange(paths: readonly string[]) {
      const path = paths[paths.length - 1];
      // The click that activated this row already acted on the file, and a
      // selection the viewer made (following the file in view) must not
      // scroll the viewer back.
      if (
        syncingSelection.current ||
        path === latest.current.selectedPath ||
        (activatedPath.current != null && activatedPath.current === path)
      ) {
        return;
      }
      const itemId = latest.current.source.pathToItemId.get(path);
      if (itemId) {
        latest.current.onSelectItem(itemId);
      }
    },
  });

  usePierreFileTreeSource(model, source, measureStats);
  usePierreFileTreeSelection(model, selectedPath, syncingSelection);

  return (
    // A file row click acts on the file like its header bar (file-activation.ts).
    // The capture phase sees the row before the tree's own click handler
    // selects it, so the action reads the state the user clicked on.
    <div className="file-tree-activation" ref={treeActivationRef}>
      <FileTree
        model={model}
        style={{ height: "100%" }}
        renderContextMenu={(item, context) => {
          if (item.kind !== "file") {
            return null;
          }
          const viewed = viewedStateByPath.get(item.path) === "viewed";
          return (
            <div className="file-tree-context-menu" role="menu">
              <button
                type="button"
                role="menuitem"
                className="menu-item"
                onClick={() => {
                  onToggleViewedPath(item.path);
                  context.close();
                }}
              >
                <Icon name={viewed ? "eye" : "check"} />
                <span className="menu-label">{viewed ? label("markNotViewed") : label("markViewed")}</span>
              </button>
            </div>
          );
        }}
      />
    </div>
  );
}

function usePierreFileTreeSource(
  model: ReturnType<typeof useFileTree>["model"],
  source: FileTreeSource,
  measureStats: MeasureText,
): void {
  const previousSource = useRef<FileTreeSource | null>(null);
  useEffect(() => {
    const previous = previousSource.current;
    previousSource.current = source;
    const plan = planPierreFileTreeRefresh(previous, source, source.paths);
    let useFullGitStatus = plan.kind === "append" ? plan.requiresFullGitStatus : false;
    if (plan.kind === "append") {
      if (plan.addedPaths.length > 0) {
        try {
          model.batch(plan.addedPaths.map((path) => ({ type: "add", path })));
          useFullGitStatus = !plan.sourceFollowsPrevious;
        } catch {
          const preparedInput = preparePresortedFileTreeInput(source.paths);
          model.resetPaths(source.paths, { preparedInput });
          useFullGitStatus = true;
        }
      }
    } else {
      const preparedInput = preparePresortedFileTreeInput(source.paths);
      model.resetPaths(source.paths, { preparedInput });
      useFullGitStatus = true;
    }
    // Setting the icons re-renders the rows, so new counts show, and adds the
    // count symbols of new files (file-tree-stats.ts).
    if (useFullGitStatus || plan.kind !== "append" || plan.addedPaths.length > 0 || source.statsChanged === true) {
      model.setIcons(fileTreeIcons(source.statsByPath.values(), measureStats));
    }
  }, [measureStats, model, source]);
}

/** "Open file search" (the native action, `diffViewerOpenFileSearch`) focuses the sidebar's filter field. */
function useFileFilterFocus(fileSearchOpen: boolean, fileSearchRequest: number): void {
  useEffect(() => {
    if (!fileSearchOpen) {
      return;
    }
    const input = document.getElementById("file-filter-input") as HTMLInputElement | null;
    input?.focus();
    input?.select();
  }, [fileSearchOpen, fileSearchRequest]);
}

function usePierreFileTreeSelection(
  model: ReturnType<typeof useFileTree>["model"],
  selectedPath: string,
  syncing: React.MutableRefObject<boolean>,
): void {
  useEffect(() => {
    syncing.current = true;
    try {
      selectPierreFileTreePath(model, selectedPath);
    } finally {
      syncing.current = false;
    }
  }, [model, selectedPath, syncing]);
}

const FILE_TREE_ITEM_HEIGHT = 29;
const FILE_TREE_FONT_FAMILY =
  'system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif';

export function getInitialFileTreeRowCount(): number {
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return 25;
  }
  return Math.min(96, Math.max(25, Math.ceil(viewportHeight / FILE_TREE_ITEM_HEIGHT)));
}

/**
 * A file row's decoration: its viewed mark, then the nonzero "+N" and "-N"
 * counts (screenshot parity: "+75 -10", "-1", "+18"). Folders get none.
 */
export function fileTreeRowDecoration(
  stats: { added: number; deleted: number } | undefined,
  label: DiffViewerLabelResolver,
  measure: MeasureText,
): FileTreeStatsDecoration | null {
  return fileTreeStatsDecoration(stats, { additions: label("additions"), deletions: label("deletions") }, measure);
}

/**
 * The tree's icon config: the built-in set, the classic list's thin folder
 * caret, and one symbol per count pair.
 */
function fileTreeIcons(stats: Iterable<{ added: number; deleted: number }>, measure: MeasureText) {
  return {
    set: "complete" as const,
    remap: { "file-tree-icon-chevron": { name: FILE_TREE_CARET_SYMBOL, width: 16, height: 16, viewBox: "0 0 16 16" } },
    spriteSheet: diffStatSpriteSheet(stats, measure, FILE_TREE_CARET_SPRITE),
  };
}

const FILE_TREE_CARET_SYMBOL = "cmux-tree-caret";
const FILE_TREE_CARET_SPRITE = `<symbol id="${FILE_TREE_CARET_SYMBOL}" viewBox="0 0 16 16"><path d="M4.5 6.5 8 10l3.5-3.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></symbol>`;
