import { CodeView, WorkerPoolContextProvider, type CodeViewHandle } from "@pierre/diffs/react";
import { parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import type { SelectedLineRange } from "@pierre/diffs";
import {
  useCallback,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import { flushSync } from "react-dom";
import "../../Resources/markdown-viewer/viewer-navigation.js";
import { copyGitApplyCommand, copyText, resolveDiffNavigationURL } from "./actions";
import { resolveDiffViewerAppearance } from "./appearance";
import { lineTextFor, type CommentFileDiff } from "./comments/anchor";
import { sidebarCommentEntries, type CommentAnnotation, type SidebarCommentEntry } from "./comments/annotations";
import {
  deleteComment as bridgeDeleteComment,
  diffCommentsBridgeAvailable,
  saveComment as bridgeSaveComment,
} from "./comments/bridge";
import { CommentComposer } from "./comments/CommentComposer";
import { commentSubmissionText } from "./comments/format";
import { resolveCommentLabels } from "./comments/labels";
import { SavedComment } from "./comments/SavedComment";
import type { DiffCommentRecord, DiffCommentSide } from "./comments/types";
import { useCommentsBootstrap } from "./comments/useCommentsBootstrap";
import { resolveDiffPreloadLanguages } from "./diff-language";
import { fileName, type DiffItem, streamPatch } from "./diff-stream";
import { withCollapsedFile } from "./collapsed-files";
import { treeFileActivation } from "./file-activation";
import { computedTranslateX, createFilesPanelMotion, type FilesPanelMotion } from "./files-panel-motion";
import { DEFERRED_PATCH_KEY, hydrateDeferredFileDiff } from "./deferred-parse";
import { filterDiffItems, isDiffFileFilterActive } from "./file-filter";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import { codeViewOptions, shikiThemeFromGhostty, workerHighlighterOptions, type DiffViewerOptions } from "./pierre-options";
import { applyDiffViewerStatusToDocument, createDiffViewerStatus } from "./status";
import { UNCOMMITTED_BASE_REF } from "./toolbar-model";
import {
  type ViewedFileState,
  type ViewedScope,
  loadViewedFiles,
  persistViewedChange,
  toggleViewedItem,
  viewedScopeFor,
  viewedScopeKey,
  viewedStateOfItem,
} from "./viewed-files";
import { buildHunkAnchors, nextHunkIndex } from "./viewer-hunks";
import { loadViewerPrefs, saveViewerPrefs } from "./viewer-prefs";
import { useDiffWrites } from "./diff-writes";
import type { DiffViewerLabelResolver } from "./labels";
import type { DiffViewerStatus } from "./status";
import type { DiffViewerConfig } from "./types";
import { createDiffTransport, DiffTransportError, type DiffTransport } from "./diff/transport";
import { FindBar } from "./find/FindBar";
import { useDiffFind, type DiffFindController } from "./find/useDiffFind";
import { useFindKeyboard } from "./find/useFindKeyboard";
import type { DiffSource, DiffTransportConfig, SessionOpened } from "./diff/generated/protocol";
import { createDiffWorkerPoolOptions } from "./worker-pool";
import { diffLanguages } from "./diff-languages/registry";
import { resolveDiffItemLanguage } from "./diff-viewer/item-languages";
import {
  adjacentItemId,
  keepStuckHeaderInView,
  presentedItem,
  scrollTargetForItem,
  visibleItemId,
} from "./diff-viewer/item-navigation";
import { type ActiveDiffSession, type AdoptedDiffSession, closeDiffSession, diffSessionRequest, diffSourceRepoRoot, isStatusOnlyPayload, pendingSessionID, validDiffSource } from "./diff-viewer/session";
import {
  type AppAction,
  type AppState,
  type DiffViewerLayout,
  initialAppState,
  itemCollapsedFileKey,
  reducer,
} from "./diff-viewer/state";
import { FileHeader } from "./diff-viewer/FileHeader";
import { FilesSidebar, FilesSidebarBackdrop, filteredFileTreeSource, getInitialFileTreeRowCount } from "./diff-viewer/FilesSidebar";
import { LoadingLayer } from "./diff-viewer/Loading";
import { DiffPill, Toolbar } from "./diff-viewer/Toolbar";
import { WorkerRenderOptionsSync } from "./diff-viewer/WorkerRenderOptionsSync";
import { useSyncedRef } from "./diff-viewer/useSyncedRef";

type ConfigProps = {
  config: DiffViewerConfig;
  initialStatus: DiffViewerStatus;
};

const registeredCustomThemeNames = new Set<string>();
export function App({ config, initialStatus }: ConfigProps) {
  const payload = config.payload ?? {};
  const label = useMemo(
    () =>
      createDiffViewerLabelResolver(payload.labels, {
        assertMissing: shouldAssertMissingLabels(),
      }),
    [payload.labels],
  );
  const appearance = useMemo(() => resolveDiffViewerAppearance(payload.appearance), [payload.appearance]);
  const transport = useDiffTransport(payload.transport);
  const [activeSessionSource, setActiveSessionSource] = useState<DiffSource | null>(
    validDiffSource(payload.sessionSource) ? payload.sessionSource : null,
  );
  const [resolvedSessionSource, setResolvedSessionSource] = useState<DiffSource | null>(activeSessionSource);
  const branchSourceByRepoRef = useRef(new Map<string, Extract<DiffSource, { kind: "branch" }>>());
  if (
    activeSessionSource?.kind === "branch" &&
    activeSessionSource.baseRef !== UNCOMMITTED_BASE_REF &&
    !branchSourceByRepoRef.current.has(activeSessionSource.repoRoot)
  ) {
    branchSourceByRepoRef.current.set(activeSessionSource.repoRoot, activeSessionSource);
  }
  const [activePatchURL, setActivePatchURL] = useState<string | undefined>(payload.patchURL);
  const [state, dispatch] = useReducer(reducer, initialAppState(config, initialStatus));
  // This mount's host writes (viewed marks, prefs): disposed with the viewer (diff-writes.ts).
  const writes = useDiffWrites();
  const latestState = useSyncedRef(state);
  const codeViewRef = useRef<CodeViewHandle<any> | null>(null);
  const codeViewScrollTopRef = useRef(0);
  const copyFallbackRef = useRef<HTMLTextAreaElement | null>(null);
  const activeSessionRef = useRef<ActiveDiffSession | null>(null);
  const adoptedSessionRef = useRef<AdoptedDiffSession | null>(null);
  const viewerContainerRef = useRef<HTMLDivElement | null>(null);
  useDiffLanguageChanges(dispatch);
  const workerPoolOptions = createDiffWorkerPoolOptions();
  const highlighterOptions = workerHighlighterOptions(state.options, appearance, state.languages);
  const payloadRepoRoot = typeof payload.repoRoot === "string" && payload.repoRoot !== "" ? payload.repoRoot : null;
  const commentRepoRoot = diffSourceRepoRoot(resolvedSessionSource ?? activeSessionSource) ?? payloadRepoRoot;
  useEffect(() => {
    const configuredTitle = typeof payload.title === "string" ? payload.title.trim() : "";
    if (configuredTitle === "") {
      return;
    }

    const activeSource = resolvedSessionSource ?? activeSessionSource;
    if (activeSource?.kind === "patch") {
      document.title = configuredTitle;
      return;
    }

    const repoRoot = diffSourceRepoRoot(activeSource) ?? payloadRepoRoot;
    const repoOption = Array.isArray(payload.repoOptions)
      ? payload.repoOptions.find((option) => option?.value === repoRoot)
      : undefined;
    const repoLabel = typeof repoOption?.label === "string" ? repoOption.label.trim() : "";
    document.title = repoLabel === "" ? configuredTitle : `${configuredTitle} — ${repoLabel}`;
  }, [activeSessionSource, payload.repoOptions, payload.title, payloadRepoRoot, resolvedSessionSource]);
  const bridgeAvailable = diffCommentsBridgeAvailable() && commentRepoRoot != null;
  const commentLabels = resolveCommentLabels(payload);
  const comments = useDiffComments({
    bridgeAvailable,
    dispatch,
    latestState,
    repoRoot: commentRepoRoot,
  });
  // One options object per options change: CodeView compares options by
  // identity of their callbacks, and a new object on every render re-rendered
  // every mounted file whenever the viewer re-rendered (a tree selection
  // change, a Viewed toggle).
  const gutterClick = useSyncedRef(comments.onGutterUtilityClick);
  const renderedCodeViewOptions = useMemo(() => {
    const options = codeViewOptions(state.options, appearance);
    options.onGutterUtilityClick = ((range: SelectedLineRange, context: { item: DiffItem }) =>
      gutterClick.current(range, context)) as any;
    return options;
  }, [appearance, gutterClick, state.options]);
  const closeActiveSession = useCallback(() => {
    const activeSession = activeSessionRef.current;
    if (!transport) {
      return Promise.resolve();
    }
    if (!activeSession) {
      if (typeof payload.capabilityToken !== "string") {
        return Promise.resolve();
      }
      return closeDiffSession(transport, {
        sessionId: pendingSessionID,
        capabilityToken: payload.capabilityToken,
      });
    }
    activeSessionRef.current = null;
    return transport
      .request({
        method: "sessionClose",
        params: activeSession,
      })
      .then(() => {})
      .catch(() => {
        if (!activeSessionRef.current) {
          activeSessionRef.current = activeSession;
        }
      });
  }, [payload.capabilityToken, transport]);
  const rememberResolvedSessionSource = useCallback((source: DiffSource) => {
    if (source.kind === "branch" && source.baseRef !== UNCOMMITTED_BASE_REF) {
      branchSourceByRepoRef.current.set(source.repoRoot, source);
    }
    setResolvedSessionSource(source);
  }, []);

  // Review-parity state: per-file "Viewed" marks (native, scoped by repo +
  // source identity) and the sidebar file filter, which hides diff sections
  // as well as tree rows so `visibleItems` is the single visible list.
  const viewedScope = viewedScopeFor(resolvedSessionSource ?? activeSessionSource, payload);
  const viewedStateOf = (item: DiffItem): ViewedFileState => viewedStateOfItem(item, state.viewedByPath);
  // Zero-latency rule (g): a filter keystroke repaints the field and the files tree in its own
  // frame; the diff column (and what follows it: find, jump, navigation) catches up in a deferred,
  // interruptible render, so laying out the new set of files never sits on the input path.
  const deferredFileFilter = useDeferredValue(state.fileFilter);
  const visibleItems = useMemo(
    () => filterDiffItems(state.items, deferredFileFilter, (item) => viewedStateOfItem(item, state.viewedByPath)),
    [deferredFileFilter, state.items, state.viewedByPath],
  );
  const treeItems = useMemo(
    () =>
      deferredFileFilter === state.fileFilter
        ? visibleItems
        : filterDiffItems(state.items, state.fileFilter, (item) => viewedStateOfItem(item, state.viewedByPath)),
    [deferredFileFilter, state.fileFilter, state.items, state.viewedByPath, visibleItems],
  );
  const visibleItemsRef = useSyncedRef(visibleItems);
  // What CodeView renders: a collapsed file as plain text, so no highlight
  // work is spent on it (see presentedItem).
  const presentedItems = useMemo(() => visibleItems.map(presentedItem), [visibleItems]);
  const filteredTreeSource = useMemo(
    () => filteredFileTreeSource(state.treeSource, state.fileFilter, treeItems),
    [state.fileFilter, state.treeSource, treeItems],
  );
  const viewedScopeRef = useSyncedRef(viewedScope);
  const toggleViewed = useCallback(
    (itemId: string) => {
      const current = latestState.current;
      const result = toggleViewedItem(current.items, current.viewedByPath, itemId);
      const change = result.change;
      if (change == null) {
        return;
      }
      const collapses =
        result.items.some((item) => item.id === itemId && item.collapsed) &&
        !current.items.some((item) => item.id === itemId && item.collapsed);
      keepStuckHeaderInView(codeViewRef, collapses ? itemId : null, () =>
        dispatch({ type: "apply-viewed", items: result.items, change }),
      );
      persistViewedChange(viewedScopeRef.current, change, writes);
    },
    [latestState, viewedScopeRef, writes],
  );
  const toggleViewedPath = useCallback(
    (path: string) => {
      const itemId = latestState.current.treeSource?.pathToItemId.get(path);
      if (itemId) {
        toggleViewed(itemId);
      }
    },
    [latestState, toggleViewed],
  );

  // The header bar and the files tree collapse or expand one file through
  // this one path, which remembers it with the other viewer preferences.
  const setItemCollapsed = useCallback(
    (itemId: string, collapsed: boolean) => {
      const current = latestState.current;
      const item = current.items.find((candidate) => candidate.id === itemId);
      if (item == null || Boolean(item.collapsed) === collapsed) {
        return;
      }
      const collapsedFiles = withCollapsedFile(
        current.collapsedFiles,
        itemCollapsedFileKey(item, current.viewedScopeKey),
        collapsed,
      );
      keepStuckHeaderInView(codeViewRef, collapsed ? itemId : null, () =>
        dispatch({ type: "set-item-collapsed", itemId, collapsed, collapsedFiles }),
      );
      saveViewerPrefs({ collapsedFiles }, writes);
    },
    [latestState, writes],
  );
  const toggleItemCollapsed = useCallback(
    (itemId: string) => {
      const item = latestState.current.items.find((candidate) => candidate.id === itemId);
      if (item != null) {
        setItemCollapsed(itemId, !item.collapsed);
      }
    },
    [latestState, setItemCollapsed],
  );

  usePageDataAttributes(state);
  useDeferredHydration(state.items, dispatch);
  useViewedFilesBootstrap(viewedScope, dispatch);
  usePendingReplacement(payload, label, dispatch, transport);
  useRenderDiff(
    config,
    transport,
    label,
    dispatch,
    latestState,
    setActivePatchURL,
    activeSessionRef,
    closeActiveSession,
    activeSessionSource,
    rememberResolvedSessionSource,
    state.renderGeneration,
    adoptedSessionRef,
  );
  useViewerPrefsBootstrap(payload, dispatch);
  useCommentsBootstrap(bridgeAvailable ? commentRepoRoot : null, comments.onLoaded);
  useOptionsDismiss(state.optionsOpen, dispatch);
  useFileSearchDismiss(state.fileSearchOpen, dispatch);

  const renderCommentAnnotation = (annotation: CommentAnnotation, item: DiffItem) => {
    const metadata = annotation.metadata;
    if (metadata.kind === "draft") {
      return (
        <CommentComposer
          labels={commentLabels}
          onCancel={() => dispatch({ type: "set-draft", draft: null })}
          onSave={(message) => comments.saveDraft(item, message)}
        />
      );
    }
    return (
      <SavedComment
        comment={metadata.comment}
        labels={commentLabels}
        onDelete={() => comments.remove(metadata.comment)}
        onSaveMessage={(message) => comments.editMessage(metadata.comment, message, item.fileDiff)}
      />
    );
  };

  const diffStreamComplete = Number.isFinite(state.metrics?.completedAt) && (state.metrics?.completedAt ?? 0) > 0;
  const commentEntries = sidebarCommentEntries(state.items, state.comments, diffStreamComplete);
  const selectCommentEntry = (entry: SidebarCommentEntry) => {
    if (entry.itemId == null) {
      return;
    }
    if (entry.anchor.state === "outdated") {
      codeViewRef.current?.scrollTo({ type: "item", id: entry.itemId, align: "start", behavior: "smooth-auto" });
    } else {
      codeViewRef.current?.scrollTo({
        type: "line",
        id: entry.itemId,
        lineNumber: entry.anchor.line,
        side: entry.comment.side,
        align: "center",
        behavior: "smooth-auto",
      });
    }
    dispatch({
      type: "set-active-item",
      itemId: entry.itemId,
      treePath: state.treeSource?.treePathByItemId.get(entry.itemId),
    });
  };

  const selectedTreePath = state.treeSource?.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath;
  // Index of the last hunk reached through n/p; -1 once a file-level jump or
  // refresh makes it stale so the next keypress re-seeds from the active file.
  const hunkNavIndex = useRef(-1);
  const scrollToItem = useCallback(
    (itemId: string) => {
      const current = latestState.current;
      const target = scrollTargetForItem(itemId, current.items);
      if (!target) {
        return;
      }
      hunkNavIndex.current = -1;
      codeViewRef.current?.scrollTo({ type: "item", id: target, align: "start", behavior: "smooth-auto" });
      dispatch({
        type: "set-active-item",
        itemId: target,
        treePath: current.treeSource?.treePathByItemId.get(target),
      });
    },
    [latestState],
  );
  // A file row click in the tree (file-activation.ts): expand and scroll,
  // collapse in place, or scroll only.
  const activateTreeFile = useCallback(
    (itemId: string) => {
      const items = visibleItemsRef.current;
      const item = items.find((candidate) => candidate.id === itemId);
      if (item == null) {
        return;
      }
      const instance = codeViewRef.current?.getInstance();
      const inPlace =
        instance != null &&
        visibleItemId(items, instance.getScrollTop(), (id) => instance.getTopForItem(id)) === itemId;
      const action = treeFileActivation(Boolean(item.collapsed), inPlace);
      if (action === "collapse") {
        setItemCollapsed(itemId, true);
        dispatch({
          type: "set-active-item",
          itemId,
          treePath: latestState.current.treeSource?.treePathByItemId.get(itemId),
        });
        return;
      }
      if (action === "expand") {
        // Lay the expanded file out before scrolling: its own top does not
        // move, so the scroll lands without a jump once its height is measured.
        flushSync(() => setItemCollapsed(itemId, false));
      }
      scrollToItem(itemId);
    },
    [latestState, scrollToItem, setItemCollapsed, visibleItemsRef],
  );
  const currentVisibleItemId = useCallback(() => {
    const current = latestState.current;
    const items = visibleItemsRef.current;
    return (
      visibleItemId(items, codeViewScrollTopRef.current, (itemId) =>
        codeViewRef.current?.getInstance()?.getTopForItem(itemId),
      ) || (items.some((item) => item.id === current.activeItemId) ? current.activeItemId : "")
    );
  }, [latestState, visibleItemsRef]);
  const jumpAdjacentFile = useCallback(
    (direction: -1 | 1) => {
      const target = adjacentItemId(currentVisibleItemId(), visibleItemsRef.current, direction);
      if (target) {
        scrollToItem(target);
      }
    },
    [currentVisibleItemId, scrollToItem, visibleItemsRef],
  );
  // Collapses or expands the file under the viewport through the header caret's path.
  const setCurrentFileCollapsed = useCallback(
    (collapsed: boolean) => {
      const target = currentVisibleItemId();
      if (target) {
        setItemCollapsed(target, collapsed);
      }
    },
    [currentVisibleItemId, setItemCollapsed],
  );
  // GitHub's `v`: toggles the file under the viewport (or the active file).
  const toggleViewedCurrentFile = useCallback(() => {
    const target = currentVisibleItemId();
    if (target) {
      toggleViewed(target);
    }
  }, [currentVisibleItemId, toggleViewed]);
  const jumpAdjacentHunk = useCallback(
    (direction: -1 | 1) => {
      const current = latestState.current;
      const anchors = buildHunkAnchors(visibleItemsRef.current);
      const index = nextHunkIndex(anchors, hunkNavIndex.current, current.activeItemId, direction);
      if (index < 0) {
        return;
      }
      const anchor = anchors[index];
      hunkNavIndex.current = index;
      codeViewRef.current?.scrollTo({
        type: "line",
        id: anchor.itemId,
        lineNumber: anchor.lineNumber,
        side: anchor.side,
        align: "center",
        behavior: "smooth-auto",
      });
      dispatch({
        type: "set-active-item",
        itemId: anchor.itemId,
        treePath: current.treeSource?.treePathByItemId.get(anchor.itemId),
      });
    },
    [latestState, visibleItemsRef],
  );
  // The tree's selection follows the file at the top of the viewer. It moves
  // only once that file has stayed on top for two frames in a row, so a fast
  // scroll across many files does not re-render the viewer and the tree on
  // every frame; the frame loop runs only until the selection is settled.
  const followFrame = useRef(0);
  const followCandidate = useRef({ itemId: "", frames: 0 });
  const handleCodeViewScroll = useCallback(
    (scrollTop: number) => {
      codeViewScrollTopRef.current = scrollTop;
      if (followFrame.current !== 0) {
        return;
      }
      const step = () => {
        followFrame.current = 0;
        const instance = codeViewRef.current?.getInstance();
        if (instance == null) {
          return;
        }
        const itemId = visibleItemId(visibleItemsRef.current, codeViewScrollTopRef.current, (id) =>
          instance.getTopForItem(id),
        );
        const current = latestState.current;
        if (itemId === "" || itemId === current.activeItemId) {
          followCandidate.current = { itemId: "", frames: 0 };
          return;
        }
        const candidate = followCandidate.current;
        candidate.frames = candidate.itemId === itemId ? candidate.frames + 1 : 1;
        candidate.itemId = itemId;
        if (candidate.frames >= 2) {
          followCandidate.current = { itemId: "", frames: 0 };
          dispatch({ type: "set-active-item", itemId, treePath: current.treeSource?.treePathByItemId.get(itemId) });
          return;
        }
        followFrame.current = requestAnimationFrame(step);
      };
      followFrame.current = requestAnimationFrame(step);
    },
    [latestState, visibleItemsRef],
  );
  const revealItem = useCallback((itemId: string) => dispatch({ type: "expand-item", itemId }), []);
  const find = useDiffFind({
    items: visibleItems,
    open: state.findOpen,
    query: state.findQuery,
    dispatch,
    codeViewRef,
    viewerContainerRef,
    revealItem,
  });
  const findBridgeRef = useSyncedRef({ open: state.findOpen, controller: find });
  useFindKeyboard(dispatch, findBridgeRef);
  useNativeViewerNavigation(
    viewerContainerRef,
    dispatch,
    jumpAdjacentFile,
    jumpAdjacentHunk,
    toggleViewedCurrentFile,
    setCurrentFileCollapsed,
    findBridgeRef,
  );
  const setStatus = (status: DiffViewerStatus) => {
    applyDiffViewerStatusToDocument(status);
    dispatch({ type: "set-status", status });
  };
  const setLayout = (layout: DiffViewerLayout) => {
    saveViewerPrefs({ layout }, writes);
    dispatch({ type: "set-option", key: "layout", value: layout });
  };
  // Dispatches an options change and persists it globally when the key is a
  // persisted preference (`collapsed` stays session-local).
  const setOption = (key: keyof DiffViewerOptions, value: any) => {
    dispatch({ type: "set-option", key, value });
    if (key !== "collapsed") {
      saveViewerPrefs({ [key]: value }, writes);
    }
  };
  const refresh = () => {
    // Pages with nothing to re-stream (baked status messages, or a pending
    // replacement without a typed session) still need the full reload so a
    // native replacement page can resolve.
    if (isStatusOnlyPayload(payload, transport, activeSessionSource)) {
      void closeActiveSession().then(() => window.location.reload());
      return;
    }
    // Soft refresh: re-open the typed session (or re-stream the patch) in
    // place so layout and the options-menu toggles survive (#5284).
    hunkNavIndex.current = -1;
    const status = createDiffViewerStatus(label("loadingDiff"), { pending: true });
    applyDiffViewerStatusToDocument(status);
    dispatch({ type: "refresh", status });
    setActivePatchURL(undefined);
    void closeActiveSession();
  };

  return (
    <div
      id="app"
      data-file-search-open={state.fileSearchOpen}
      data-file-filter-active={isDiffFileFilterActive(state.fileFilter)}
    >
      <Toolbar
        config={config}
        transport={transport}
        label={label}
        onJump={scrollToItem}
        onNavigate={(url) => {
          setStatus(createDiffViewerStatus(label("loadingDiff"), { pending: true }));
          // Session cleanup is best-effort and can wait on WebKit's reply path.
          // Do not make source/repository/base selection wait for it: navigation
          // starts a new typed session and must stay responsive.
          void closeActiveSession();
          window.location.href = resolveDiffNavigationURL(url);
        }}
        activeSessionSource={resolvedSessionSource ?? activeSessionSource}
        onSelectSessionSource={(source, opened) => {
          const currentSource = resolvedSessionSource ?? activeSessionSource;
          // Branch reopens the base last used in this repository; Uncommitted
          // (a branch session against HEAD) is always exactly that.
          // A session the host already opened (branchChange) is adopted as it is.
          const selectedSource = opened
            ? opened.session.source
            : source.kind === "branch" &&
                source.baseRef !== UNCOMMITTED_BASE_REF &&
                (currentSource?.kind !== "branch" ||
                  currentSource.baseRef === UNCOMMITTED_BASE_REF ||
                  source.baseRef == null)
              ? (branchSourceByRepoRef.current.get(source.repoRoot) ?? source)
              : source;
          if (selectedSource.kind === "branch" && selectedSource.baseRef !== UNCOMMITTED_BASE_REF) {
            branchSourceByRepoRef.current.set(selectedSource.repoRoot, selectedSource);
          }
          const status = createDiffViewerStatus(label("loadingDiff"), { pending: true });
          applyDiffViewerStatusToDocument(status);
          dispatch({ type: "reset-diff", status });
          setActivePatchURL(undefined);
          void closeActiveSession();
          adoptedSessionRef.current = opened ?? null;
          setResolvedSessionSource(selectedSource);
          setActiveSessionSource(selectedSource);
        }}
        rememberedBranch={(() => {
          const repo = diffSourceRepoRoot(resolvedSessionSource ?? activeSessionSource);
          return repo ? (branchSourceByRepoRef.current.get(repo) ?? null) : null;
        })()}
        pill={
          <DiffPill
            dispatch={dispatch}
            externalURL={
              typeof payload.externalURL === "string" && payload.externalURL.length > 0 ? payload.externalURL : null
            }
            label={label}
            onCopyGitApply={async () => {
              try {
                const message = await copyGitApplyCommand(activePatchURL, label, copyFallbackRef.current);
                dispatch({ type: "set-copy-feedback", message });
              } catch {
                dispatch({ type: "set-copy-feedback", message: label("copyFailedGitApplyCommand") });
              }
            }}
            onReload={refresh}
            onSetLayout={setLayout}
            onSetOption={setOption}
            state={state}
          />
        }
        state={state}
        visibleItems={visibleItems}
      />
      <section id="content" style={{ "--cmux-diff-files-width": `${state.filesWidth}px` } as React.CSSProperties}>
        <FilesSidebarBackdrop label={label} onClose={() => closeFileSearch(dispatch)} open={state.fileSearchOpen} />
        {/* Covers the strip a closing panel uncovers until the diff widens (files-panel-motion.ts). */}
        <div id="files-motion-curtain" aria-hidden="true" />
        <FilesSidebar
          commentEntries={commentEntries}
          commentLabels={commentLabels}
          hasDraft={state.draft != null}
          label={label}
          onSelectComment={selectCommentEntry}
          onActivateItem={activateTreeFile}
          onSelectItem={scrollToItem}
          onToggleViewedPath={toggleViewedPath}
          selectedPath={selectedTreePath}
          treeSource={filteredTreeSource}
          viewedStateOf={viewedStateOf}
          visibleItemCount={visibleItems.length}
          dispatch={dispatch}
          state={state}
        />
        <main id="viewer" aria-label={label("diffViewer")}>
          {state.findOpen ? (
            <FindBar controller={find} label={label} query={state.findQuery} requestToken={state.findRequest} />
          ) : null}
          {state.items.length > 0 ? (
            <WorkerPoolContextProvider poolOptions={workerPoolOptions} highlighterOptions={highlighterOptions}>
              <WorkerRenderOptionsSync codeViewRef={codeViewRef} highlighterOptions={highlighterOptions} />
              <CodeView
                ref={codeViewRef}
                className="code-view-root"
                containerRef={viewerContainerRef}
                items={presentedItems}
                onScroll={handleCodeViewScroll}
                options={renderedCodeViewOptions}
                renderCustomHeader={(item) => (
                  <FileHeader
                    item={item as DiffItem}
                    label={label}
                    onCopyPath={(path) => {
                      copyText(path, copyFallbackRef.current).then(
                        () => dispatch({ type: "set-copy-feedback", message: label("copiedFilePath") }),
                        () => dispatch({ type: "set-copy-feedback", message: label("copyFailedFilePath") }),
                      );
                    }}
                    onLoadDiff={() => dispatch({ type: "expand-item", itemId: item.id })}
                    onToggleCollapsed={() => toggleItemCollapsed(item.id)}
                    onToggleViewed={() => toggleViewed(item.id)}
                    viewedState={viewedStateOf(item as DiffItem)}
                  />
                )}
                renderAnnotation={(annotation, item) =>
                  renderCommentAnnotation(annotation as CommentAnnotation, item as DiffItem)
                }
              />
            </WorkerPoolContextProvider>
          ) : null}
        </main>
        <LoadingLayer label={label} status={state.status} />
      </section>
      <textarea ref={copyFallbackRef} aria-hidden="true" readOnly tabIndex={-1} className="copy-fallback-textarea" />
    </div>
  );
}

/**
 * Bundles the diff comment handlers: loading persisted comments, opening a
 * draft from the gutter utility, and saving/editing/deleting. Saved comments
 * carry a precomputed `submissionText`; native code pools them per workspace
 * and consumes the pool on TextBox submit.
 */
function useDiffComments({
  bridgeAvailable,
  dispatch,
  latestState,
  repoRoot,
}: {
  bridgeAvailable: boolean;
  dispatch: React.Dispatch<AppAction>;
  latestState: React.MutableRefObject<AppState>;
  repoRoot: string | null;
}) {
  const activeRepoRoot = useSyncedRef(repoRoot);
  const onLoaded = useCallback(
    (comments: DiffCommentRecord[]) => dispatch({ type: "replace-comments", comments }),
    [dispatch],
  );

  const onGutterUtilityClick = (range: SelectedLineRange, context: { item: DiffItem }) => {
    const side: DiffCommentSide = range.side === "deletions" ? "deletions" : "additions";
    dispatch({
      type: "set-draft",
      draft: {
        itemId: context.item.id,
        side,
        startLine: Math.min(range.start, range.end),
        endLine: Math.max(range.start, range.end),
      },
    });
  };

  const saveDraft = (item: DiffItem, message: string) => {
    const draft = latestState.current.draft;
    if (draft == null || draft.itemId !== item.id || message.trim() === "") {
      return;
    }
    const input = {
      filePath: fileName(item.fileDiff, ""),
      side: draft.side,
      startLine: draft.startLine,
      endLine: draft.endLine,
      lineText: lineTextFor(item.fileDiff, draft.side, draft.endLine) ?? "",
      message,
    };
    const record = { ...input, submissionText: commentSubmissionText(input, item.fileDiff) };
    const save =
      bridgeAvailable && repoRoot != null
        ? bridgeSaveComment(repoRoot, record)
        : Promise.resolve(localCommentRecord(record));
    save
      .then((saved) => {
        if (activeRepoRoot.current !== repoRoot) {
          return;
        }
        dispatch({ type: "upsert-comment", comment: saved });
        dispatch({ type: "set-draft", draft: null });
      })
      .catch((error) => console.warn("cmux diff comment save failed", error));
  };

  const editMessage = (comment: DiffCommentRecord, message: string, fileDiff: CommentFileDiff | null | undefined) => {
    if (message.trim() === "") {
      return;
    }
    const edited = { ...comment, message, updatedAt: new Date().toISOString() };
    const updated = { ...edited, submissionText: commentSubmissionText(edited, fileDiff) };
    const save = bridgeAvailable && repoRoot != null ? bridgeSaveComment(repoRoot, updated) : Promise.resolve(updated);
    save
      .then((saved) => {
        if (activeRepoRoot.current === repoRoot) {
          dispatch({ type: "upsert-comment", comment: saved });
        }
      })
      .catch((error) => console.warn("cmux diff comment edit failed", error));
  };

  const remove = (comment: DiffCommentRecord) => {
    const targetRepoRoot = repoRoot;
    if (bridgeAvailable && repoRoot != null) {
      bridgeDeleteComment(repoRoot, comment.id).catch((error) =>
        console.warn("cmux diff comment delete failed", error),
      );
    }
    if (activeRepoRoot.current === targetRepoRoot) {
      dispatch({ type: "remove-comment", id: comment.id });
    }
  };

  return { editMessage, onGutterUtilityClick, onLoaded, remove, saveDraft };
}

function localCommentRecord(input: Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt">): DiffCommentRecord {
  const now = new Date().toISOString();
  return { ...input, id: crypto.randomUUID(), createdAt: now, updatedAt: now };
}

function useViewerPrefsBootstrap(payload: any, dispatch: React.Dispatch<AppAction>) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    loadViewerPrefs()
      .then((prefs) => {
        dispatch({
          type: "apply-persisted-options",
          prefs,
          allowLayout: payload.layoutSource !== "explicit",
        });
      })
      .catch(() => {
        // Preferences are a convenience; boot continues with payload defaults.
      });
  }, [dispatch, payload]);
}

/**
 * Loads the persisted "Viewed" marks whenever the reviewed change's identity
 * (repo + source) changes. Cleanup invalidates an older load so a slow reply
 * cannot overwrite marks after a source switch; an unknown scope clears them.
 */
function useViewedFilesBootstrap(scope: ViewedScope | null, dispatch: React.Dispatch<AppAction>): void {
  const scopeKey = viewedScopeKey(scope);
  useEffect(() => {
    const currentScope = scope;
    // Clear the previous scope's marks before the new diff streams in, so no
    // file of the new source collapses on a mark that belongs to the old one.
    dispatch({ type: "begin-viewed-load", scopeKey });
    if (currentScope == null || scopeKey === "") {
      return;
    }
    let active = true;
    loadViewedFiles(currentScope)
      .then((entries) => {
        if (active) {
          dispatch({ type: "replace-viewed", scopeKey, entries });
        }
      })
      .catch((error) => {
        if (active) {
          console.warn("cmux diff viewed state load failed", error);
        }
      });
    return () => {
      active = false;
    };
    // `scope` is a fresh object per render; `scopeKey` is its identity.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dispatch, scopeKey]);
}

/// Re-detects every file's language when the host installs new user languages or overrides.
function useDiffLanguageChanges(dispatch: React.Dispatch<AppAction>): void {
  useEffect(() => diffLanguages.subscribe(() => dispatch({ type: "relanguage-items" })), [dispatch]);
}

function useRenderDiff(
  config: DiffViewerConfig,
  transport: DiffTransport | null,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  latestState: React.MutableRefObject<AppState>,
  onPatchURL: (url: string) => void,
  activeSessionRef: React.MutableRefObject<ActiveDiffSession | null>,
  closeActiveSession: () => Promise<void>,
  sessionSource: DiffSource | null,
  onResolvedSessionSource: (source: DiffSource) => void,
  renderGeneration: number,
  adoptedSessionRef: React.MutableRefObject<AdoptedDiffSession | null>,
) {
  useEffect(() => {
    if (isStatusOnlyPayload(config.payload, transport, sessionSource)) {
      return;
    }
    // A soft refresh bumps the generation: the cleanup below closes the
    // superseded session and this effect re-streams in place.
    document.body.dataset.diffRenderGeneration = String(renderGeneration);
    const payload = config.payload ?? {};
    const appearance = resolveDiffViewerAppearance(payload.appearance);
    for (const theme of [appearance.themes.light, appearance.themes.dark]) {
      if (theme.name && !registeredCustomThemeNames.has(theme.name)) {
        registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme, appearance)));
        registeredCustomThemeNames.add(theme.name);
      }
    }
    let cancelled = false;
    const streamAbortController = new AbortController();
    const handlePageHide = () => {
      void closeActiveSession();
    };
    window.addEventListener("pagehide", handlePageHide);
    void (async () => {
      try {
        let patchURL = payload.patchURL as string | undefined;
        // Taken once: a later render of the same source opens its own session.
        const adopted = adoptedSessionRef.current;
        adoptedSessionRef.current = null;
        const session = adopted ? null : diffSessionRequest(payload, transport, sessionSource);
        if (adopted || session) {
          let opened: SessionOpened;
          if (adopted) {
            opened = adopted.session;
          } else {
            const result = await transport!.request({ method: "sessionOpen", params: session! });
            if (result.type !== "sessionOpened") {
              throw new DiffTransportError("invalidResponse", "Diff transport did not open a session");
            }
            opened = result.value;
          }
          const result = { value: opened };
          const openedSession = {
            sessionId: opened.sessionId,
            capabilityToken: adopted?.capabilityToken ?? String(payload.capabilityToken ?? ""),
          };
          if (cancelled) {
            await closeDiffSession(transport!, openedSession);
            return;
          }
          activeSessionRef.current = openedSession;
          onResolvedSessionSource(result.value.source);
          // Older sidecars omit the field; the lockfile heuristic still applies.
          const generatedPaths = Array.isArray(result.value.generatedPaths)
            ? result.value.generatedPaths.filter((path): path is string => typeof path === "string")
            : [];
          dispatch({ type: "set-generated-paths", paths: generatedPaths });
          patchURL = result.value.patch.id;
        }
        if (cancelled || !patchURL) {
          return;
        }
        onPatchURL(patchURL);
        const streamedItems: DiffItem[] = [];
        dispatch({ type: "set-status", status: createDiffViewerStatus(label("parsingDiff"), { loading: true }) });
        await streamPatch({
          getCollapsed: () => latestState.current.options.collapsed,
          initialFileTreeRowCount: getInitialFileTreeRowCount(),
          label,
          signal: streamAbortController.signal,
          onBatch: (items) => {
            if (cancelled) return;
            streamedItems.push(...items);
            dispatch({ type: "append-items", items });
          },
          onComplete: (metrics) => {
            if (cancelled) return;
            dispatch({ type: "set-metrics", metrics });
            const items = streamedItems;
            if (items.length === 0) {
              const emptyMessage =
                typeof payload.emptyMessage === "string" ? payload.emptyMessage : label("noFileDiffs");
              dispatch({
                type: "set-status",
                status: createDiffViewerStatus(emptyMessage, { error: false, loading: false, statusOnly: true }),
              });
              return;
            }
            const themes = Array.from(new Set([appearance.theme?.light, appearance.theme?.dark].filter(Boolean)));
            const langs = Array.from(
              new Set(
                items.flatMap((item) => {
                  const diff = item.fileDiff ?? {};
                  return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff);
                }),
              ),
            );
            preloadHighlighter({ themes, langs: langs.length > 0 ? langs : ["text"] }).catch((error) =>
              console.warn("cmux diff highlighter preload failed", error),
            );
          },
          onMetrics: (metrics) => {
            if (!cancelled) dispatch({ type: "set-metrics", metrics });
          },
          onRename: (rename) => {
            if (!cancelled) dispatch({ type: "rename-item", oldId: rename.oldId, newId: rename.newId });
          },
          onTreeSource: (source) => {
            if (!cancelled) dispatch({ type: "set-tree-source", source });
          },
          isGeneratedPath: (path) => latestState.current.generatedPaths.includes(path),
          parsePatchFiles,
          patchURL,
          processFile,
        });
      } catch (error) {
        if (cancelled) {
          return;
        }
        const empty = error instanceof DiffTransportError && error.code === "emptyDiff";
        if (!empty) {
          // Error objects JSON.stringify to {} in the native console mirror,
          // so serialize the message and stack explicitly.
          console.error(
            "cmux diff viewer render failed",
            String((error as any)?.stack ?? (error as any)?.message ?? error),
          );
        }
        const emptyMessage = typeof payload.emptyMessage === "string" ? payload.emptyMessage : label("noFileDiffs");
        dispatch({
          type: "set-status",
          status: createDiffViewerStatus(empty ? emptyMessage : label("renderFailed"), {
            error: !empty,
            loading: false,
            statusOnly: true,
          }),
        });
      }
    })();
    return () => {
      cancelled = true;
      streamAbortController.abort();
      window.removeEventListener("pagehide", handlePageHide);
      void closeActiveSession();
    };
  }, [
    activeSessionRef,
    closeActiveSession,
    config,
    dispatch,
    label,
    latestState,
    onPatchURL,
    onResolvedSessionSource,
    renderGeneration,
    sessionSource,
    transport,
    adoptedSessionRef,
  ]);
}

function usePendingReplacement(
  payload: any,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  transport: DiffTransport | null,
) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    if (payload.pendingReplacement === true) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage ?? label("loadingDiff"), { loading: true, pending: true }),
      });
      if (diffSessionRequest(payload, transport)) {
        return;
      }
      // The native host replaces the file and navigates this surface when Git
      // generation completes. Custom-scheme resources never use an HTTP wait
      // endpoint, so keep the loading state until that navigation arrives.
      if (window.location.protocol === "cmux-diff-viewer:") {
        return;
      }
      fetch("/__cmux_diff_viewer_wait" + window.location.pathname, { cache: "no-store" })
        .then(async (response) => {
          if (!response.ok) {
            throw new Error("replacement failed");
          }
          const text = await response.text();
          if (!text.includes('data-cmux-diff-pending="true"')) {
            window.location.reload();
          }
        })
        .catch((error) => {
          document.documentElement.dataset.cmuxDiffWait = "failed";
          dispatch({
            type: "set-status",
            status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }),
          });
          console.warn("cmux diff viewer deferred load failed", error);
        });
      return;
    }
    if (typeof payload.statusMessage === "string" && payload.statusMessage.length > 0) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage, {
          error: payload.statusIsError === true,
          loading: false,
          statusOnly: true,
        }),
      });
    }
  }, [dispatch, label, payload, transport]);
}

/**
 * Parses a deferred file (deferred-parse.ts) once it is expanded, by Load
 * diff, its header bar, the files tree or find. The parse runs in a task
 * after the expanding commit, so the click's own frame stays short, and its
 * result replaces the placeholder in place.
 */
function useDeferredHydration(items: DiffItem[], dispatch: React.Dispatch<AppAction>) {
  const scheduled = useRef(new Set<string>());
  useEffect(() => {
    for (const item of items) {
      if (item.collapsed || item.fileDiff?.[DEFERRED_PATCH_KEY] == null || scheduled.current.has(item.id)) {
        continue;
      }
      scheduled.current.add(item.id);
      const placeholder = item.fileDiff;
      setTimeout(() => {
        scheduled.current.delete(item.id);
        const fileDiff = hydrateDeferredFileDiff(placeholder, processFile);
        if (fileDiff != null) {
          resolveDiffItemLanguage({ ...item, fileDiff } as DiffItem);
          dispatch({ type: "hydrate-item", itemId: item.id, fileDiff });
        }
      }, 0);
    }
  }, [dispatch, items]);
}

function setDataset(dataset: DOMStringMap, key: string, value: string): void {
  if (dataset[key] !== value) dataset[key] = value;
}

function usePageDataAttributes(state: AppState) {
  // The files panel shows and hides through its motion (files-panel-motion.ts),
  // which flips `data-files-hidden` in this commit's frame and slides the
  // panel on the compositor afterwards.
  const filesPanelMotion = useRef<FilesPanelMotion | null>(null);
  useLayoutEffect(() => {
    filesPanelMotion.current ??= createFilesPanelMotion({
      panel: () => document.getElementById("files-sidebar"),
      curtain: () => document.getElementById("files-motion-curtain"),
      timelineTime: () => {
        const time = document.timeline?.currentTime;
        return typeof time === "number" ? time : null;
      },
      body: document.body,
      currentOffset: (panel) => computedTranslateX(panel as HTMLElement),
      requestFrame: (callback) => requestAnimationFrame(() => callback()),
      reducedMotion: () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false,
    });
    filesPanelMotion.current.set(state.filesVisible);
  }, [state.filesVisible]);
  useEffect(() => {
    // Written only when a value changes: an attribute write on <html> or <body> invalidates style
    // for the whole document, and this runs after every state change (an input's frame included).
    const body = document.body.dataset;
    const root = document.documentElement.dataset;
    setDataset(body, "loading", state.status.loading ? "true" : "false");
    setDataset(root, "layout", state.options.layout);
    setDataset(root, "wordWrap", String(state.options.wordWrap));
    setDataset(root, "diffIndicators", state.options.diffIndicators);
    setDataset(body, "generatedPathCount", String(state.generatedPaths.length));
    if (state.metrics) {
      setDataset(body, "streamFileCount", String(state.metrics.fileCount ?? state.items.length));
      setDataset(body, "streamRenderableFileCount", String(state.metrics.renderableFileCount ?? state.items.length));
      setDataset(body, "streamFlushCount", String(state.metrics.flushCount ?? 0));
      setDataset(body, "streamMaxBatchSize", String(state.metrics.maxBatchSize ?? 0));
      setDataset(body, "streamTreeRefreshCount", String(state.metrics.treeRefreshCount ?? 0));
      if (Number.isFinite(state.metrics.completedAt) && state.metrics.completedAt > 0) {
        setDataset(body, "streamElapsedMs", String(Math.round(state.metrics.completedAt - state.metrics.startedAt)));
      }
    }
    applyDiffViewerStatusToDocument(state.status);
  }, [state]);
}

function useNativeViewerNavigation(
  viewerRef: React.MutableRefObject<HTMLDivElement | null>,
  dispatch: React.Dispatch<AppAction>,
  onJumpAdjacentFile: (direction: -1 | 1) => void,
  onJumpAdjacentHunk: (direction: -1 | 1) => void,
  onToggleViewed: () => void,
  onSetCurrentCollapsed: (collapsed: boolean) => void,
  findBridgeRef: React.MutableRefObject<{ open: boolean; controller: DiffFindController }>,
) {
  useEffect(() => {
    window.__cmuxPerformDiffViewerNavigationAction = (action: string) => {
      const viewer = viewerRef.current;
      if (viewer && CmuxViewerNavigation.performAction(action, viewer)) {
        return true;
      }
      const findBridge = findBridgeRef.current;
      switch (action) {
        case "diffViewerOpenFileSearch":
          dispatch({ type: "request-file-search" });
          return true;
        case "diffViewerNextFile":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentFile(1);
          return true;
        case "diffViewerPreviousFile":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentFile(-1);
          return true;
        case "diffViewerNextHunk":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentHunk(1);
          return true;
        case "diffViewerPreviousHunk":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentHunk(-1);
          return true;
        case "diffViewerToggleViewed":
          onToggleViewed();
          return true;
        case "diffViewerCollapseFile":
          onSetCurrentCollapsed(true);
          return true;
        case "diffViewerExpandFile":
          onSetCurrentCollapsed(false);
          return true;
        case "diffViewerOpenFind":
          dispatch({ type: "request-find" });
          return true;
        case "diffViewerFindNext":
          if (!findBridge.open) return false;
          findBridge.controller.goToNext();
          return true;
        case "diffViewerFindPrevious":
          if (!findBridge.open) return false;
          findBridge.controller.goToPrevious();
          return true;
        case "diffViewerCloseFind":
          if (!findBridge.open) return false;
          findBridge.controller.closeFind();
          return true;
      }
      return false;
    };
    document.documentElement.dataset.cmuxViewerNavigationReady = "true";
    document.dispatchEvent(new window.Event("cmux-diff-viewer-navigation-readiness-change"));
    const disposeManualInputReset = CmuxViewerNavigation.installManualInputReset({
      target: document,
      getScroller: () => viewerRef.current!,
    });
    return () => {
      delete window.__cmuxPerformDiffViewerNavigationAction;
      delete document.documentElement.dataset.cmuxViewerNavigationReady;
      document.dispatchEvent(new window.Event("cmux-diff-viewer-navigation-readiness-change"));
      disposeManualInputReset();
    };
  }, [
    dispatch,
    findBridgeRef,
    onJumpAdjacentFile,
    onJumpAdjacentHunk,
    onSetCurrentCollapsed,
    onToggleViewed,
    viewerRef,
  ]);
}

function useOptionsDismiss(optionsOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!optionsOpen) {
      return;
    }
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest("#diff-pill")) {
        return;
      }
      dispatch({ type: "set-options-open", open: false });
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        dispatch({ type: "set-options-open", open: false });
      }
    };
    document.addEventListener("click", closeOnOutsideClick);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("click", closeOnOutsideClick);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [dispatch, optionsOpen]);
}

export function closeFileSearch(dispatch: React.Dispatch<AppAction>, targetDocument: Document = document) {
  dispatch({ type: "set-file-search-open", open: false });
  const trigger = targetDocument.getElementById("jump-search-button") ?? targetDocument.getElementById("jump-select");
  trigger?.focus();
}

export function shouldDismissFileSearch(key: string, narrowViewport: boolean): boolean {
  return key === "Escape" && narrowViewport;
}

function useFileSearchDismiss(fileSearchOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!fileSearchOpen) {
      return;
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (shouldDismissFileSearch(event.key, window.matchMedia("(max-width: 520px)").matches)) {
        event.preventDefault();
        closeFileSearch(dispatch);
      }
    };
    document.addEventListener("keydown", closeOnEscape);
    return () => document.removeEventListener("keydown", closeOnEscape);
  }, [dispatch, fileSearchOpen]);
}

function useDiffTransport(config: DiffTransportConfig | undefined): DiffTransport | null {
  const transportRef = useRef<DiffTransport | null | undefined>(undefined);
  if (transportRef.current === undefined) {
    transportRef.current = createDiffTransport(config);
  }
  useEffect(() => {
    const transport = transportRef.current;
    return () => transport?.close();
  }, []);
  return transportRef.current;
}
