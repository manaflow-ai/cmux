import { CodeView, WorkerPoolContextProvider, type CodeViewHandle } from "@pierre/diffs/react";
import type { SelectedLineRange } from "@pierre/diffs";
import { useCallback, useDeferredValue, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { flushSync } from "react-dom";
import "../../Resources/markdown-viewer/viewer-navigation.js";
import { copyGitApplyCommand, copyText, resolveDiffNavigationURL } from "./actions";
import { resolveDiffViewerAppearance } from "./appearance";
import { sidebarCommentEntries, type CommentAnnotation, type SidebarCommentEntry } from "./comments/annotations";
import { diffCommentsBridgeAvailable } from "./comments/bridge";
import { CommentComposer } from "./comments/CommentComposer";
import { resolveCommentLabels } from "./comments/labels";
import { SavedComment } from "./comments/SavedComment";
import { useCommentsBootstrap } from "./comments/useCommentsBootstrap";
import { type DiffItem } from "./diff-stream";
import { withCollapsedFile } from "./collapsed-files";
import { treeFileActivation } from "./file-activation";
import { filterDiffItems, isDiffFileFilterActive } from "./file-filter";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import { codeViewOptions, workerHighlighterOptions, type DiffViewerOptions } from "./pierre-options";
import { applyDiffViewerStatusToDocument, createDiffViewerStatus } from "./status";
import { UNCOMMITTED_BASE_REF } from "./toolbar-model";
import { type ViewedFileState, persistViewedChange, toggleViewedItem, viewedScopeFor, viewedStateOfItem } from "./viewed-files";
import { buildHunkAnchors, nextHunkIndex } from "./viewer-hunks";
import { saveViewerPrefs } from "./viewer-prefs";
import { useDiffWrites } from "./diff-writes";
import type { DiffViewerStatus } from "./status";
import type { DiffViewerConfig } from "./types";
import { FindBar } from "./find/FindBar";
import { useDiffFind } from "./find/useDiffFind";
import { useFindKeyboard } from "./find/useFindKeyboard";
import type { DiffSource } from "./diff/generated/protocol";
import { createDiffWorkerPoolOptions } from "./worker-pool";
import {
  adjacentItemId,
  keepStuckHeaderInView,
  presentedItem,
  scrollTargetForItem,
  visibleItemId,
} from "./diff-viewer/item-navigation";
import { type ActiveDiffSession, type AdoptedDiffSession, closeDiffSession, diffSourceRepoRoot, isStatusOnlyPayload, pendingSessionID, validDiffSource } from "./diff-viewer/session";
import { type DiffViewerLayout, initialAppState, itemCollapsedFileKey, reducer } from "./diff-viewer/state";
import { FileHeader } from "./diff-viewer/FileHeader";
import { FilesSidebar, FilesSidebarBackdrop, filteredFileTreeSource } from "./diff-viewer/FilesSidebar";
import { LoadingLayer } from "./diff-viewer/Loading";
import { DiffPill, Toolbar } from "./diff-viewer/Toolbar";
import { WorkerRenderOptionsSync } from "./diff-viewer/WorkerRenderOptionsSync";
import { useSyncedRef } from "./diff-viewer/useSyncedRef";
import { useViewedFilesBootstrap, useViewerPrefsBootstrap } from "./diff-viewer/bootstrap";
import { closeFileSearch, useFileSearchDismiss, useNativeViewerNavigation, useOptionsDismiss, usePageDataAttributes } from "./diff-viewer/page-effects";
import { useDiffComments } from "./diff-viewer/useDiffComments";
import { useDeferredHydration, useDiffLanguageChanges, useDiffTransport, usePendingReplacement, useRenderDiff } from "./diff-viewer/useRenderDiff";

type ConfigProps = {
  config: DiffViewerConfig;
  initialStatus: DiffViewerStatus;
};

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
