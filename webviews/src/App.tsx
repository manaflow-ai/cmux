import { CodeView, WorkerPoolContextProvider, type CodeViewHandle, useWorkerPool } from "@pierre/diffs/react";
import { getFiletypeFromFileName, parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import type { SelectedLineRange } from "@pierre/diffs";
import { FileTree, useFileTree } from "@pierre/trees/react";
import { preparePresortedFileTreeInput } from "@pierre/trees";
import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import "../../Resources/markdown-viewer/viewer-navigation.js";
import { copyGitApplyCommand, resolveDiffNavigationURL } from "./actions";
import { resolveDiffViewerAppearance } from "./appearance";
import { BranchBasePicker, type BranchPickerPayload } from "./BranchBasePicker";
import { lineTextFor, type CommentFileDiff } from "./comments/anchor";
import {
  applyCommentAnnotations,
  sidebarCommentEntries,
  withCommentAnnotations,
  type CommentAnnotation,
  type SidebarCommentEntry,
} from "./comments/annotations";
import {
  deleteComment as bridgeDeleteComment,
  diffCommentsBridgeAvailable,
  saveComment as bridgeSaveComment,
} from "./comments/bridge";
import { CommentComposer } from "./comments/CommentComposer";
import { CommentsSidebarSection } from "./comments/CommentsSection";
import { commentSubmissionText } from "./comments/format";
import { resolveCommentLabels, type DiffCommentLabels } from "./comments/labels";
import { SavedComment } from "./comments/SavedComment";
import type {
  CommentDraft,
  DiffCommentRecord,
  DiffCommentSide,
} from "./comments/types";
import { useCommentsBootstrap } from "./comments/useCommentsBootstrap";
import { resolveDiffFileLanguage, resolveDiffPreloadLanguages } from "./diff-language";
import { fileName, type DiffItem, type FileTreeSource, type StreamMetrics, streamPatch } from "./diff-stream";
import { applyPierreFileTreeGitStatus, planPierreFileTreeRefresh, selectPierreFileTreePath } from "./file-tree-refresh";
import { Icon, type IconName } from "./icons";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import {
  codeViewOptions,
  fileTreeUnsafeCSS,
  shikiThemeFromGhostty,
  workerHighlighterOptions,
  type DiffViewerOptions,
} from "./pierre-options";
import { applyDiffViewerStatusToDocument, createDiffViewerStatus } from "./status";
import { resolveToolbarOverflow } from "./toolbar-overflow";
import { useToolbarWidth } from "./useToolbarWidth";
import type { DiffViewerLabelResolver } from "./labels";
import type { DiffViewerStatus } from "./status";
import type { DiffViewerConfig } from "./types";
import { createDiffWorkerPoolOptions } from "./worker-pool";

type ConfigProps = {
  config: DiffViewerConfig;
  initialStatus: DiffViewerStatus;
};

type AppState = {
  activeItemId: string;
  activeTreePath: string;
  comments: DiffCommentRecord[];
  copyFeedback: string;
  draft: CommentDraft | null;
  fileSearchOpen: boolean;
  fileSearchRequest: number;
  filesWidth: number;
  filesVisible: boolean;
  items: DiffItem[];
  languages: string[];
  metrics: StreamMetrics | null;
  options: DiffViewerOptions;
  optionsOpen: boolean;
  status: DiffViewerStatus;
  treeSource: FileTreeSource | null;
};

type AppAction =
  | { type: "append-items"; items: DiffItem[] }
  | { type: "remove-comment"; id: string }
  | { type: "rename-item"; oldId: string; newId: string }
  | { type: "set-active-item"; itemId: string; treePath?: string }
  | { type: "set-comments"; comments: DiffCommentRecord[] }
  | { type: "set-copy-feedback"; message: string }
  | { type: "set-draft"; draft: CommentDraft | null }
  | { type: "set-file-search-open"; open: boolean }
  | { type: "request-file-search" }
  | { type: "set-files-width"; width: number }
  | { type: "set-files-visible"; visible: boolean }
  | { type: "set-metrics"; metrics: StreamMetrics }
  | { type: "set-option"; key: keyof DiffViewerOptions; value: any }
  | { type: "set-options-open"; open: boolean }
  | { type: "set-status"; status: DiffViewerStatus }
  | { type: "set-tree-source"; source: FileTreeSource }
  | { type: "upsert-comment"; comment: DiffCommentRecord };

const fileSkeletonWidths = ["82%", "64%", "76%", "58%", "70%", "46%"];
const diffSkeletonWidths = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
const defaultWorkerModuleURL = "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/worker-pool/worker-portable.js";
const persistedLayoutKey = "cmux.diffViewer.layout";
type DiffViewerLayout = DiffViewerOptions["layout"];

function initialAppState(config: DiffViewerConfig, initialStatus: DiffViewerStatus): AppState {
  const payload = config.payload ?? {};
  return {
    activeItemId: "",
    activeTreePath: "",
    comments: [],
    copyFeedback: "",
    draft: null,
    fileSearchOpen: false,
    fileSearchRequest: 0,
    filesWidth: 252,
    filesVisible: true,
    items: [],
    languages: ["text"],
    metrics: null,
    options: {
      collapsed: false,
      diffIndicators: "bars",
      expandUnchanged: false,
      layout: initialDiffViewerLayout(payload),
      lineNumbers: true,
      showBackgrounds: true,
      wordDiffs: false,
      wordWrap: false,
    } as DiffViewerOptions,
    optionsOpen: false,
    status: initialStatus,
    treeSource: null,
  };
}

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
  case "append-items": {
    const nextItems = action.items.map((item) => {
      resolveDiffItemLanguage(item);
      const annotated = withCommentAnnotations(item, state.comments, state.draft);
      return state.options.collapsed ? { ...annotated, collapsed: true } : annotated;
    });
    const languages = mergeLanguages(state.languages, nextItems.flatMap(diffItemPreloadLanguages));
    return {
      ...state,
      activeItemId: state.activeItemId || nextItems[0]?.id || "",
      items: [...state.items, ...nextItems],
      languages,
      status: state.status.loading ? createDiffViewerStatus("", { loading: false }) : state.status,
    };
  }
  case "remove-comment": {
    const comments = state.comments.filter((comment) => comment.id !== action.id);
    return {
      ...state,
      comments,
      items: applyCommentAnnotations(state.items, comments, state.draft),
    };
  }
  case "rename-item":
    return {
      ...state,
      activeItemId: state.activeItemId === action.oldId ? action.newId : state.activeItemId,
      draft: state.draft?.itemId === action.oldId
        ? { ...state.draft, itemId: action.newId }
        : state.draft,
      items: state.items.map((item) => (
        item.id === action.oldId || item.id === action.newId
          ? { ...item, id: action.newId, version: (item.version ?? 0) + 1 }
          : item
      )),
    };
  case "set-active-item":
    return {
      ...state,
      activeItemId: action.itemId,
      activeTreePath: action.treePath ?? state.activeTreePath,
    };
  case "set-comments":
    return {
      ...state,
      comments: action.comments,
      items: applyCommentAnnotations(state.items, action.comments, state.draft),
    };
  case "set-copy-feedback":
    return { ...state, copyFeedback: action.message };
  case "set-draft":
    return {
      ...state,
      draft: action.draft,
      items: applyCommentAnnotations(state.items, state.comments, action.draft),
    };
  case "set-file-search-open":
    return { ...state, fileSearchOpen: action.open, filesVisible: action.open ? true : state.filesVisible };
  case "request-file-search":
    return { ...state, fileSearchOpen: true, fileSearchRequest: state.fileSearchRequest + 1, filesVisible: true };
  case "set-files-width":
    return { ...state, filesWidth: action.width };
  case "set-files-visible":
    return { ...state, filesVisible: action.visible };
  case "set-metrics":
    return { ...state, metrics: action.metrics };
  case "set-option":
    if (action.key === "collapsed") {
      return {
        ...state,
        options: { ...state.options, collapsed: Boolean(action.value) },
        items: state.items.map((item) => ({
          ...item,
          collapsed: Boolean(action.value),
          version: (item.version ?? 0) + 1,
        })),
      };
    }
    return { ...state, options: { ...state.options, [action.key]: action.value } };
  case "set-options-open":
    return { ...state, optionsOpen: action.open };
  case "set-status":
    return { ...state, status: action.status };
  case "set-tree-source": {
    const source = action.source;
    const nextPath = state.activeItemId ? source.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath : state.activeTreePath;
    return {
      ...state,
      activeTreePath: nextPath,
      treeSource: source,
    };
  }
  case "upsert-comment": {
    const exists = state.comments.some((comment) => comment.id === action.comment.id);
    const comments = exists
      ? state.comments.map((comment) => (comment.id === action.comment.id ? action.comment : comment))
      : [...state.comments, action.comment];
    return {
      ...state,
      comments,
      items: applyCommentAnnotations(state.items, comments, state.draft),
    };
  }
  }
}

export function App({ config, initialStatus }: ConfigProps) {
  const payload = config.payload ?? {};
  const label = createDiffViewerLabelResolver(payload.labels, {
    assertMissing: shouldAssertMissingLabels(),
  });
  const appearance = resolveDiffViewerAppearance(payload.appearance);
  const [state, dispatch] = useReducer(reducer, initialAppState(config, initialStatus));
  const latestState = useSyncedRef(state);
  const codeViewRef = useRef<CodeViewHandle<any> | null>(null);
  const codeViewScrollTopRef = useRef(0);
  const copyFallbackRef = useRef<HTMLTextAreaElement | null>(null);
  const viewerContainerRef = useRef<HTMLDivElement | null>(null);
  const workerModuleURL = resolveDiffViewerAssetURL(config.assets?.workerModuleURL);
  const workerPoolOptions = createDiffWorkerPoolOptions(workerModuleURL);
  const highlighterOptions = workerHighlighterOptions(state.options, appearance, state.languages);
  const repoRoot = typeof payload.repoRoot === "string" && payload.repoRoot !== "" ? payload.repoRoot : null;
  const bridgeAvailable = diffCommentsBridgeAvailable() && repoRoot != null;
  const commentLabels = resolveCommentLabels(payload);
  const comments = useDiffComments({
    bridgeAvailable,
    dispatch,
    latestState,
    repoRoot,
  });
  const renderedCodeViewOptions = codeViewOptions(state.options, appearance);
  renderedCodeViewOptions.onGutterUtilityClick = comments.onGutterUtilityClick as any;

  usePageDataAttributes(state);
  usePendingReplacement(payload, label, dispatch);
  useRenderDiff(config, label, dispatch, latestState);
  useCommentsBootstrap(bridgeAvailable ? repoRoot : null, comments.onLoaded);
  useOptionsDismiss(state.optionsOpen, dispatch);

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
  const scrollToItem = useCallback((itemId: string) => {
    const current = latestState.current;
    const target = scrollTargetForItem(itemId, current.items);
    if (!target) {
      return;
    }
    codeViewRef.current?.scrollTo({ type: "item", id: target, align: "start", behavior: "smooth-auto" });
    dispatch({
      type: "set-active-item",
      itemId: target,
      treePath: current.treeSource?.treePathByItemId.get(target),
    });
  }, [latestState]);
  const jumpAdjacentFile = useCallback((direction: -1 | 1) => {
    const current = latestState.current;
    const visibleItem = visibleItemId(
      current.items,
      codeViewScrollTopRef.current,
      (itemId) => codeViewRef.current?.getInstance()?.getTopForItem(itemId),
    );
    const target = adjacentItemId(visibleItem || current.activeItemId, current.items, direction);
    if (target) {
      scrollToItem(target);
    }
  }, [latestState, scrollToItem]);
  const handleCodeViewScroll = useCallback((scrollTop: number) => {
    codeViewScrollTopRef.current = scrollTop;
  }, []);
  useNativeViewerNavigation(viewerContainerRef, dispatch, jumpAdjacentFile);
  const setStatus = (status: DiffViewerStatus) => {
    applyDiffViewerStatusToDocument(status);
    dispatch({ type: "set-status", status });
  };
  const setLayout = (layout: DiffViewerLayout) => {
    persistDiffViewerLayout(layout);
    dispatch({ type: "set-option", key: "layout", value: layout });
  };

  return (
    <div id="app">
      <Toolbar
        config={config}
        label={label}
        onCopyGitApply={async () => {
          try {
            const message = await copyGitApplyCommand(payload.patchURL, label, copyFallbackRef.current);
            dispatch({ type: "set-copy-feedback", message });
          } catch {
            dispatch({ type: "set-copy-feedback", message: label("copyFailedGitApplyCommand") });
          }
        }}
        onJump={scrollToItem}
        onNavigate={(url) => {
          setStatus(createDiffViewerStatus(label("loadingDiff"), { pending: true }));
          window.location.href = resolveDiffNavigationURL(url);
        }}
        onReload={() => window.location.reload()}
        onSetLayout={setLayout}
        dispatch={dispatch}
        state={state}
      />
      <section id="content" style={{ "--cmux-diff-files-width": `${state.filesWidth}px` } as React.CSSProperties}>
        <FilesSidebar
          commentEntries={commentEntries}
          commentLabels={commentLabels}
          hasDraft={state.draft != null}
          label={label}
          onSelectComment={selectCommentEntry}
          onSelectItem={scrollToItem}
          selectedPath={selectedTreePath}
          dispatch={dispatch}
          state={state}
        />
        <main id="viewer" aria-label={label("diffViewer")}>
          {state.items.length > 0 ? (
            <WorkerPoolContextProvider
              poolOptions={workerPoolOptions}
              highlighterOptions={highlighterOptions}
            >
              <WorkerRenderOptionsSync codeViewRef={codeViewRef} highlighterOptions={highlighterOptions} />
              <CodeView
                ref={codeViewRef}
                className="code-view-root"
                containerRef={viewerContainerRef}
                items={state.items}
                onScroll={handleCodeViewScroll}
                options={renderedCodeViewOptions}
                renderAnnotation={(annotation, item) =>
                  renderCommentAnnotation(annotation as CommentAnnotation, item as DiffItem)}
              />
            </WorkerPoolContextProvider>
          ) : null}
        </main>
        <LoadingLayer label={label} status={state.status} />
      </section>
      <textarea
        ref={copyFallbackRef}
        aria-hidden="true"
        readOnly
        tabIndex={-1}
        className="copy-fallback-textarea"
      />
    </div>
  );
}

function resolveDiffViewerAssetURL(rawURL: string | undefined): URL {
  return new URL(rawURL || defaultWorkerModuleURL, window.location.href);
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
  const onLoaded = useCallback(
    (comments: DiffCommentRecord[]) => dispatch({ type: "set-comments", comments }),
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
    const save = bridgeAvailable && repoRoot != null
      ? bridgeSaveComment(repoRoot, record)
      : Promise.resolve(localCommentRecord(record));
    save
      .then((saved) => {
        dispatch({ type: "upsert-comment", comment: saved });
        dispatch({ type: "set-draft", draft: null });
      })
      .catch((error) => console.warn("cmux diff comment save failed", error));
  };

  const editMessage = (
    comment: DiffCommentRecord,
    message: string,
    fileDiff: CommentFileDiff | null | undefined,
  ) => {
    if (message.trim() === "") {
      return;
    }
    const edited = { ...comment, message, updatedAt: new Date().toISOString() };
    const updated = { ...edited, submissionText: commentSubmissionText(edited, fileDiff) };
    const save = bridgeAvailable && repoRoot != null
      ? bridgeSaveComment(repoRoot, updated)
      : Promise.resolve(updated);
    save
      .then((saved) => dispatch({ type: "upsert-comment", comment: saved }))
      .catch((error) => console.warn("cmux diff comment edit failed", error));
  };

  const remove = (comment: DiffCommentRecord) => {
    if (bridgeAvailable && repoRoot != null) {
      bridgeDeleteComment(repoRoot, comment.id)
        .catch((error) => console.warn("cmux diff comment delete failed", error));
    }
    dispatch({ type: "remove-comment", id: comment.id });
  };

  return { editMessage, onGutterUtilityClick, onLoaded, remove, saveDraft };
}

function localCommentRecord(
  input: Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt">,
): DiffCommentRecord {
  const now = new Date().toISOString();
  return { ...input, id: crypto.randomUUID(), createdAt: now, updatedAt: now };
}

function initialDiffViewerLayout(payload: Record<string, any>): DiffViewerLayout {
  const payloadLayout = parseDiffViewerLayout(payload.layout);
  if (payload.layoutSource === "explicit" && payloadLayout) {
    return payloadLayout;
  }
  return readPersistedDiffViewerLayout() ?? payloadLayout ?? "unified";
}

function readPersistedDiffViewerLayout(): DiffViewerLayout | null {
  try {
    return parseDiffViewerLayout(window.localStorage.getItem(persistedLayoutKey));
  } catch {
    return null;
  }
}

function persistDiffViewerLayout(layout: DiffViewerLayout): void {
  try {
    window.localStorage.setItem(persistedLayoutKey, layout);
  } catch {
    // Storage may be unavailable for some generated viewer origins.
  }
}

function parseDiffViewerLayout(value: unknown): DiffViewerLayout | null {
  return value === "split" || value === "unified" ? value : null;
}

function WorkerRenderOptionsSync({
  codeViewRef,
  highlighterOptions,
}: {
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>;
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>;
}) {
  useWorkerRenderOptionsSync(highlighterOptions, codeViewRef);
  return null;
}

function Toolbar({
  config,
  dispatch,
  label,
  onCopyGitApply,
  onJump,
  onNavigate,
  onReload,
  onSetLayout,
  state,
}: {
  config: DiffViewerConfig;
  dispatch: React.Dispatch<AppAction>;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onJump: (itemId: string) => void;
  onNavigate: (url: string) => void;
  onReload: () => void;
  onSetLayout: (layout: DiffViewerLayout) => void;
  state: AppState;
}) {
  const payload = config.payload ?? {};
  const externalURL =
    typeof payload.externalURL === "string" && payload.externalURL.length > 0 ? payload.externalURL : null;
  const toolbarRef = useRef<HTMLElement>(null);
  const toolbarWidth = useToolbarWidth(toolbarRef);
  // Optional ACCESSORY controls, HIGH priority first (last = first to overflow).
  // Drop order at narrowing: external link -> layout toggle -> files toggle. Each
  // has a canonical copy in the "..." menu, so overflowing one only hides its
  // duplicate bar icon and it stays reachable from the menu. The source select,
  // repo select, and Base picker are NOT in this list: they are always rendered
  // in the bar (a native <select> has no menu equivalent, so the repo select must
  // never be dropped — it shrinks/ellipsizes in place instead). Estimated widths
  // include each control's ~4px inter-item gap.
  const overflowItems = [
    { id: "files-toggle" as const, width: TOOLBAR_ICON_SLOT },
    { id: "layout-toggle" as const, width: TOOLBAR_ICON_SLOT },
    ...(externalURL ? [{ id: "external-link" as const, width: TOOLBAR_ICON_SLOT }] : []),
  ];
  const overflow =
    toolbarWidth == null
      ? new Set<string>()
      : new Set(
          resolveToolbarOverflow({
            available: toolbarWidth,
            // Always-present zone: source select + repo select + Base picker +
            // "..." button + horizontal padding. Generous so we shed before, not
            // after, overlap; the CSS clip covers any residual under-estimate. The
            // repo select is always in the bar now, so reserve its slot too (it
            // shrinks in place rather than overflowing).
            reserved: TOOLBAR_ALWAYS_PRESENT_WIDTH + (hasRepoSelect(payload) ? TOOLBAR_REPO_SELECT_MIN : 0),
            items: overflowItems,
          }).overflow,
        );
  const showFilesToggle = !overflow.has("files-toggle");
  const showLayoutToggle = !overflow.has("layout-toggle");
  const showExternalLink = externalURL != null && !overflow.has("external-link");
  return (
    <header id="toolbar" ref={toolbarRef}>
      <SourceControls label={label} onNavigate={onNavigate} payload={payload} />
      {/* The jump-to-file select duplicates the Files sidebar (both scroll to a
          file). It is the only file-jump control when the sidebar is hidden, so
          it always renders, but its centered middle grid track is collapsed via
          CSS whenever the sidebar is actually visible (sidebar shown AND viewport
          wide enough that the sidebar is not media-auto-hidden), letting
          toolbar-left reclaim the space. */}
      <div className="toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5">
        <JumpSelect items={state.items} label={label} onJump={onJump} selectedItemId={state.activeItemId} />
      </div>
      <div className="toolbar-actions flex items-center gap-1.5">
        {showExternalLink ? (
          <a
            id="external-link"
            className="toolbar-icon"
            href={externalURL ?? undefined}
            target="_blank"
            rel="noreferrer"
            title={label("openSourceURL")}
            aria-label={label("openSourceURL")}
          >
            <Icon name="external" />
          </a>
        ) : null}
        {showLayoutToggle ? (
          <button
            id="layout-toggle"
            className="toolbar-icon"
            type="button"
            title={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")}
            aria-label={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")}
            onClick={() => onSetLayout(state.options.layout === "split" ? "unified" : "split")}
          >
            <Icon name={state.options.layout} />
          </button>
        ) : null}
        <button
          id="options-button"
          className="toolbar-icon"
          type="button"
          title={label("options")}
          aria-label={label("options")}
          aria-expanded={state.optionsOpen}
          aria-controls="options-menu"
          onClick={() => dispatch({ type: "set-options-open", open: !state.optionsOpen })}
        >
          <Icon name="dots" />
        </button>
        {showFilesToggle ? (
          <button
            id="files-toggle"
            className="toolbar-icon"
            type="button"
            title={state.filesVisible ? label("hideFiles") : label("showFiles")}
            aria-label={state.filesVisible ? label("hideFiles") : label("showFiles")}
            aria-pressed={state.filesVisible}
            onClick={() => dispatch({ type: "set-files-visible", visible: !state.filesVisible })}
          >
            <Icon name="files" />
          </button>
        ) : null}
        <span id="copy-feedback" className="visually-hidden" aria-live="polite">
          {state.copyFeedback}
        </span>
      </div>
      {state.optionsOpen ? (
        <OptionsMenu
          dispatch={dispatch}
          externalURL={externalURL}
          label={label}
          onCopyGitApply={onCopyGitApply}
          onReload={onReload}
          onSetLayout={onSetLayout}
          state={state}
        />
      ) : null}
    </header>
  );
}

// Pixel slot for one toolbar-actions icon button: 20px control + ~8px gap. The
// resolver only uses these as relative estimates; the CSS `overflow: clip` on
// the toolbar cells is the hard no-overlap guarantee, so exactness is not load
// bearing.
const TOOLBAR_ICON_SLOT = 28;
// Width reserved for the always-present zone (source select + Base picker + the
// "..." button + horizontal padding/gaps). Deliberately generous: the optional
// controls shed early rather than allowing the always-present zone to overflow.
const TOOLBAR_ALWAYS_PRESENT_WIDTH = 248;
// Min width the always-present repo select can shrink to (its CSS `min-width`
// floor of 56px + ~4px gap). It ellipsizes in place down to this floor rather
// than overflowing, so reserve only the floor, not its full natural width.
const TOOLBAR_REPO_SELECT_MIN = 60;

function hasRepoSelect(payload: any): boolean {
  return Array.isArray(payload?.repoOptions) && payload.repoOptions.length >= 2;
}

function SourceControls({
  label,
  onNavigate,
  payload,
}: {
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  payload: any;
}) {
  return (
    <div className="toolbar-left flex min-w-0 items-center gap-1.5">
      <NavigationSelect
        ariaLabel={label("diffTarget")}
        fallbackValue=""
        id="source-select"
        options={payload.sourceOptions}
        onNavigate={onNavigate}
      />
      {/* The repo select is ALWAYS rendered (a native <select> has no "..." menu
          equivalent, so dropping it would strand multi-repo users). It shrinks
          and ellipsizes in place via field-sizing + the .toolbar-left clip. */}
      <NavigationSelect
        ariaLabel={label("repoPath")}
        fallbackValue={payload.repoRoot ?? ""}
        id="repo-select"
        options={payload.repoOptions}
        onNavigate={onNavigate}
      />
      <BaseControl label={label} onNavigate={onNavigate} payload={payload} />
    </div>
  );
}

/**
 * Renders the searchable Base button+popover when the backend supplies
 * `payload.branchPicker` (FROZEN CONTRACT). Falls back to the legacy capped
 * `<select>` for older backends that only send `payload.baseOptions`.
 */
function BaseControl({
  label,
  onNavigate,
  payload,
}: {
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  payload: any;
}) {
  const picker = resolveBranchPicker(payload);
  if (picker) {
    return <BranchBasePicker label={label} onNavigate={onNavigate} picker={picker} />;
  }
  return (
    <NavigationSelect
      ariaLabel={label("branchBase")}
      fallbackValue={payload.branchBaseRef ?? ""}
      id="base-select"
      options={payload.baseOptions}
      onNavigate={onNavigate}
    />
  );
}

// Reads the FROZEN CONTRACT `branchPicker` object. In dev, a `?cmuxBranchPickerMock=1`
// query flag injects a local sample so the popover can be exercised without a
// wired backend. Production behavior is unchanged when the flag is absent.
function resolveBranchPicker(payload: any): BranchPickerPayload | null {
  const value = payload?.branchPicker;
  // Opt into the new picker only when the full FROZEN CONTRACT shape is present:
  // refsURL and regenerateURLTemplate must be non-empty strings (selection does
  // `regenerateURLTemplate.replace(...)`, which throws if it is missing), and
  // currentRef/headRef must be strings (rendered in the button label). Anything
  // missing falls back to the legacy <select>.
  if (isValidBranchPickerPayload(value)) {
    return value;
  }
  if (import.meta.env?.DEV && devBranchPickerMockEnabled()) {
    return devBranchPickerMock();
  }
  return null;
}

function isValidBranchPickerPayload(value: any): value is BranchPickerPayload {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof value.refsURL === "string" && value.refsURL !== "" &&
    typeof value.regenerateURLTemplate === "string" && value.regenerateURLTemplate !== "" &&
    typeof value.currentRef === "string" &&
    typeof value.headRef === "string",
  );
}

function devBranchPickerMockEnabled(): boolean {
  try {
    return new URLSearchParams(window.location.search).get("cmuxBranchPickerMock") === "1";
  } catch {
    return false;
  }
}

function devBranchPickerMock(): BranchPickerPayload {
  return {
    repoRoot: "/tmp/mock-repo",
    headRef: "feat-x",
    currentRef: "main",
    currentReason: "fork point",
    confidence: "low",
    aheadBehind: { ahead: 12, behind: 3 },
    refsURL: "data:application/json," + encodeURIComponent(JSON.stringify({
      groups: [
        { id: "suggested", label: "Suggested", rows: [
          { ref: "main", label: "main", reason: "fork point", confidence: "low", current: true },
          { ref: "origin/main", label: "origin/main", reason: "PR base" },
        ] },
        { id: "worktrees", label: "Worktrees", rows: [
          { ref: "feat-x", label: "feat-x", worktreeDir: "../worktrees/feat-x" },
        ] },
        { id: "branches", label: "Branches", rows: [
          { ref: "develop", label: "develop", secondary: "2 days ago" },
          { ref: "release/1.0", label: "release/1.0", secondary: "1 week ago" },
        ] },
        // Large remotes group so the render cap (top N + "... more") is
        // exercisable in DEV without a wired backend.
        { id: "remotes", label: "Remotes", rows: Array.from({ length: 2304 }, (_value, index) => ({
          ref: `origin/feature-${index}`,
          label: `origin/feature-${index}`,
        })) },
      ],
    })),
    regenerateURLTemplate: "about:blank#base={ref}",
  };
}

function NavigationSelect({
  ariaLabel,
  fallbackValue,
  id,
  onNavigate,
  options,
}: {
  ariaLabel: string;
  fallbackValue: string;
  id: string;
  onNavigate: (url: string) => void;
  options: any[] | undefined;
}) {
  if (!Array.isArray(options) || options.length < 2) {
    return null;
  }
  const selected = options.find((option) => option.selected) ?? options.find((option) => !option.disabled);
  return (
    <select
      id={id}
      aria-label={ariaLabel}
      defaultValue={selected?.value ?? fallbackValue}
      title={ariaLabel}
      onChange={(event) => {
        const next = options.find((option) => option.value === event.currentTarget.value);
        if (!next?.url) {
          event.currentTarget.value = selected?.value ?? fallbackValue;
          return;
        }
        onNavigate(next.url);
      }}
    >
      {options.map((option) => (
        <option
          key={option.value}
          value={option.value}
          disabled={option.disabled || !option.url}
          title={option.message}
        >
          {option.label}
        </option>
      ))}
    </select>
  );
}

function JumpSelect({
  items,
  label,
  onJump,
  selectedItemId,
}: {
  items: DiffItem[];
  label: DiffViewerLabelResolver;
  onJump: (itemId: string) => void;
  selectedItemId: string;
}) {
  if (items.length === 0) {
    return null;
  }
  return (
    <select
      id="jump-select"
      aria-label={label("jumpToFile")}
      value={selectedItemId}
      onChange={(event) => onJump(event.currentTarget.value)}
    >
      <option value="">{label("jumpToFile")}</option>
      {items.map((item) => (
        <option key={item.id} value={item.id}>
          {fileName(item.fileDiff, label("untitled"))}
        </option>
      ))}
    </select>
  );
}

function OptionsMenu({
  dispatch,
  externalURL,
  label,
  onCopyGitApply,
  onReload,
  onSetLayout,
  state,
}: {
  dispatch: React.Dispatch<AppAction>;
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onReload: () => void;
  onSetLayout: (layout: DiffViewerLayout) => void;
  state: AppState;
}) {
  const toggle = (key: keyof DiffViewerOptions) => dispatch({ type: "set-option", key, value: !state.options[key] });
  return (
    <div id="options-menu" aria-label={label("options")}>
      <MenuButton icon="refresh" label={label("refresh")} onClick={onReload} />
      <MenuButton checked={state.options.wordWrap} icon="wrap" label={state.options.wordWrap ? label("disableWordWrap") : label("enableWordWrap")} onClick={() => toggle("wordWrap")} />
      <MenuButton checked={state.options.collapsed} icon={state.options.collapsed ? "expand" : "collapse"} label={state.options.collapsed ? label("expandAllDiffs") : label("collapseAllDiffs")} onClick={() => toggle("collapsed")} />
      <div className="menu-separator" />
      {/* Secondary actions that can overflow from the bar at narrow widths are
          always listed here so they stay reachable regardless of what the bar
          decided to drop. The bar hides its duplicate icon button when it
          overflows; the menu copy is the canonical fallback. */}
      <MenuButton icon={state.options.layout} label={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")} onClick={() => onSetLayout(state.options.layout === "split" ? "unified" : "split")} />
      {externalURL ? (
        <MenuButton icon="external" label={label("openSourceURL")} onClick={() => window.open(externalURL, "_blank", "noreferrer")} />
      ) : null}
      <MenuButton checked={state.filesVisible} icon="files" label={state.filesVisible ? label("hideFiles") : label("showFiles")} onClick={() => dispatch({ type: "set-files-visible", visible: !state.filesVisible })} />
      <MenuButton checked={state.options.expandUnchanged} icon="document" label={state.options.expandUnchanged ? label("collapseUnchangedContext") : label("expandUnchangedContext")} onClick={() => toggle("expandUnchanged")} />
      <MenuButton checked={state.options.showBackgrounds} icon="background" label={state.options.showBackgrounds ? label("hideBackgrounds") : label("showBackgrounds")} onClick={() => toggle("showBackgrounds")} />
      <MenuButton checked={state.options.lineNumbers} icon="numbers" label={state.options.lineNumbers ? label("hideLineNumbers") : label("showLineNumbers")} onClick={() => toggle("lineNumbers")} />
      <MenuButton checked={state.options.wordDiffs} icon="word" label={state.options.wordDiffs ? label("disableWordDiffs") : label("enableWordDiffs")} onClick={() => toggle("wordDiffs")} />
      <div className="menu-item menu-segment">
        <Icon name="bars" />
        <span className="menu-label">{label("indicatorStyle")}</span>
        <span className="menu-segment-controls">
          {[
            { value: "bars", icon: "bars", label: label("bars") },
            { value: "classic", icon: "classic", label: label("classic") },
            { value: "none", icon: "eye", label: label("none") },
          ].map((option) => (
            <button
              key={option.value}
              type="button"
              className="segment-button"
              title={option.label}
              aria-label={option.label}
              aria-pressed={state.options.diffIndicators === option.value}
              onClick={() => dispatch({ type: "set-option", key: "diffIndicators", value: option.value })}
            >
              <Icon name={option.icon as IconName} />
            </button>
          ))}
        </span>
      </div>
      <div className="menu-separator" />
      <MenuButton icon="clipboard" label={label("copyGitApplyCommand")} onClick={onCopyGitApply} />
    </div>
  );
}

function MenuButton({
  checked,
  icon,
  label,
  onClick,
}: {
  checked?: boolean;
  icon: Parameters<typeof Icon>[0]["name"];
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="menu-item"
      aria-pressed={checked == null ? undefined : checked}
      onClick={onClick}
    >
      <Icon name={icon} />
      <span className="menu-label">{label}</span>
      <span className="menu-check">{checked ? <Icon name="check" /> : null}</span>
    </button>
  );
}

function FilesSidebar({
  commentEntries,
  commentLabels,
  dispatch,
  hasDraft,
  label,
  onSelectComment,
  onSelectItem,
  selectedPath,
  state,
}: {
  commentEntries: SidebarCommentEntry[];
  commentLabels: DiffCommentLabels;
  dispatch: React.Dispatch<AppAction>;
  hasDraft: boolean;
  label: DiffViewerLabelResolver;
  onSelectComment: (entry: SidebarCommentEntry) => void;
  onSelectItem: (itemId: string) => void;
  selectedPath: string;
  state: AppState;
}) {
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
    <aside id="files-sidebar" aria-label={label("changedFiles")} aria-hidden={!state.filesVisible} inert={!state.filesVisible}>
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
      <div id="files-header">
        <span id="files-title">
          <span>{label("files")}</span>
          <span id="files-count">{state.treeSource?.pathCount ?? 0}</span>
        </span>
        <span id="files-header-actions">
          <button
            id="file-search-toggle"
            type="button"
            title={state.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch")}
            aria-label={state.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch")}
            aria-pressed={state.fileSearchOpen}
            disabled={!state.treeSource}
            onClick={() => dispatch({ type: "set-file-search-open", open: !state.fileSearchOpen })}
          >
            <Icon name="search" />
          </button>
        </span>
      </div>
      <div id="file-list">
        {state.treeSource ? (
          <PierreFileTree
            fileSearchOpen={state.fileSearchOpen}
            fileSearchRequest={state.fileSearchRequest}
            label={label}
            onSelectItem={onSelectItem}
            selectedPath={selectedPath}
            source={state.treeSource}
          />
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
  fileSearchOpen,
  fileSearchRequest,
  label,
  onSelectItem,
  selectedPath,
  source,
}: {
  fileSearchOpen: boolean;
  fileSearchRequest: number;
  label: DiffViewerLabelResolver;
  onSelectItem: (itemId: string) => void;
  selectedPath: string;
  source: FileTreeSource;
}) {
  const latest = useSyncedRef({ label, onSelectItem, source });
  const [initialPreparedInput] = useState(() => preparePresortedFileTreeInput(source.paths));
  const { model } = useFileTree({
    flattenEmptyDirectories: false,
    id: "cmux-diff-file-tree",
    initialExpansion: "open",
    initialSelectedPaths: selectedPath ? [selectedPath] : [],
    initialVisibleRowCount: getInitialFileTreeRowCount(),
    itemHeight: 24,
    overscan: 12,
    preparedInput: initialPreparedInput,
    search: true,
    searchBlurBehavior: "retain",
    stickyFolders: true,
    gitStatus: source.gitStatus as any,
    sort: () => 0,
    unsafeCSS: fileTreeUnsafeCSS(),
    onSelectionChange(paths: readonly string[]) {
      const path = paths[paths.length - 1];
      const itemId = latest.current.source.pathToItemId.get(path);
      if (itemId) {
        latest.current.onSelectItem(itemId);
      }
    },
  });

  usePierreFileTreeSource(model, source);
  usePierreFileTreeSearch(model, fileSearchOpen, fileSearchRequest);
  usePierreFileTreeSelection(model, selectedPath);

  return <FileTree model={model} style={{ height: "100%" }} />;
}

function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div key={`${width}-${index}`} className="grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]">
          <span className="size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span className="h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" style={{ width: index % 2 === 0 ? "34px" : "24px" }} />
        </div>
      ))}
    </div>
  );
}

function LoadingDiffSkeleton() {
  return (
    <div className="diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3" aria-hidden="true">
      <div className="mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3">
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" />
      </div>
      <div className="space-y-[13px] px-3 py-1">
        {diffSkeletonWidths.map((width, index) => (
          <div key={`${width}-${index}`} className="grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4">
            <span className="h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" />
            <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          </div>
        ))}
      </div>
    </div>
  );
}

function LoadingLayer({ label, status }: { label: DiffViewerLabelResolver; status: DiffViewerStatus }) {
  if (!status.loading && !status.pending && !status.statusOnly && !status.error) {
    return null;
  }
  return (
    <div id="loading-layer" aria-live="polite">
      <div id="status" data-error={status.error ? "true" : "false"} data-pending={status.pending ? "true" : "false"}>
        <span id="status-icon" aria-hidden="true" />
        <span id="status-text">{status.message || label("loadingDiff")}</span>
      </div>
      {status.loading || status.pending ? <LoadingDiffSkeleton /> : null}
    </div>
  );
}

function useSyncedRef<T>(value: T): React.MutableRefObject<T> {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

function useWorkerRenderOptionsSync(
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>,
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>,
): void {
  const workerPool = useWorkerPool();
  const syncedOptions = useRef<ReturnType<typeof workerHighlighterOptions> | null>(null);
  useEffect(() => {
    if (!workerPool || sameWorkerHighlighterOptions(syncedOptions.current, highlighterOptions)) {
      return;
    }
    let active = true;
    syncedOptions.current = highlighterOptions;
    workerPool.setRenderOptions(highlighterOptions)
      .then(() => {
        if (active) {
          codeViewRef.current?.getInstance()?.render(true);
        }
      })
      .catch((error: unknown) => console.warn("cmux diff worker render options update failed", error));
    return () => {
      active = false;
    };
  }, [codeViewRef, highlighterOptions, workerPool]);
}

function sameWorkerHighlighterOptions(
  previous: ReturnType<typeof workerHighlighterOptions> | null,
  next: ReturnType<typeof workerHighlighterOptions>,
): boolean {
  return previous?.lineDiffType === next.lineDiffType &&
    sameStringArray(previous?.langs, next.langs) &&
    previous?.maxLineDiffLength === next.maxLineDiffLength &&
    previous?.preferredHighlighter === next.preferredHighlighter &&
    sameThemeOption(previous?.theme, next.theme) &&
    previous?.tokenizeMaxLineLength === next.tokenizeMaxLineLength &&
    previous?.useTokenTransformer === next.useTokenTransformer;
}

function sameStringArray(previous: readonly string[] | undefined, next: readonly string[] | undefined): boolean {
  if (previous === next) {
    return true;
  }
  if (previous == null || next == null || previous.length !== next.length) {
    return false;
  }
  return previous.every((value, index) => value === next[index]);
}

function sameThemeOption(
  previous: ReturnType<typeof workerHighlighterOptions>["theme"] | undefined,
  next: ReturnType<typeof workerHighlighterOptions>["theme"],
): boolean {
  if (previous === next) {
    return true;
  }
  if (typeof previous !== "object" || previous == null || typeof next !== "object" || next == null) {
    return false;
  }
  return (previous as { dark?: string }).dark === (next as { dark?: string }).dark &&
    (previous as { light?: string }).light === (next as { light?: string }).light;
}

function usePierreFileTreeSource(
  model: ReturnType<typeof useFileTree>["model"],
  source: FileTreeSource,
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
    applyPierreFileTreeGitStatus(model as any, source, useFullGitStatus);
  }, [model, source]);
}

function usePierreFileTreeSearch(
  model: ReturnType<typeof useFileTree>["model"],
  fileSearchOpen: boolean,
  fileSearchRequest: number,
): void {
  useEffect(() => {
    if (fileSearchOpen) {
      const wasOpen = model.isSearchOpen();
      model.openSearch(wasOpen ? model.getSearchValue() : "");
      if (wasOpen) {
        const container = model.getFileTreeContainer();
        const root = container?.shadowRoot ?? container?.getRootNode();
        (root as ParentNode | undefined)?.querySelector<HTMLInputElement>("[data-file-tree-search-input]")?.focus();
      }
    } else {
      model.closeSearch();
    }
  }, [fileSearchOpen, fileSearchRequest, model]);
}

function usePierreFileTreeSelection(model: ReturnType<typeof useFileTree>["model"], selectedPath: string): void {
  useEffect(() => {
    selectPierreFileTreePath(model, selectedPath);
  }, [model, selectedPath]);
}

function useRenderDiff(
  config: DiffViewerConfig,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  latestState: React.MutableRefObject<AppState>,
) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current || isStatusOnlyPayload(config.payload)) {
      return;
    }
    started.current = true;
    const payload = config.payload ?? {};
    const appearance = resolveDiffViewerAppearance(payload.appearance);
    if (appearance.themes.light.name) {
      registerCustomTheme(appearance.themes.light.name, () => Promise.resolve(shikiThemeFromGhostty(appearance.themes.light, appearance)));
    }
    if (appearance.themes.dark.name) {
      registerCustomTheme(appearance.themes.dark.name, () => Promise.resolve(shikiThemeFromGhostty(appearance.themes.dark, appearance)));
    }
    const streamedItems: DiffItem[] = [];
    dispatch({ type: "set-status", status: createDiffViewerStatus(label("parsingDiff"), { loading: true }) });
    streamPatch({
      getCollapsed: () => latestState.current.options.collapsed,
      initialFileTreeRowCount: getInitialFileTreeRowCount(),
      label,
      onBatch: (items) => {
        streamedItems.push(...items);
        dispatch({ type: "append-items", items });
      },
      onComplete: (metrics) => {
        dispatch({ type: "set-metrics", metrics });
        const items = streamedItems;
        if (items.length === 0) {
          dispatch({ type: "set-status", status: createDiffViewerStatus(label("noFileDiffs"), { error: true, loading: false, statusOnly: true }) });
          return;
        }
        const themes = Array.from(new Set([appearance.theme?.light, appearance.theme?.dark].filter(Boolean)));
        const langs = Array.from(new Set(items.flatMap((item) => {
          const diff = item.fileDiff ?? {};
          return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff, getFiletypeFromFileName);
        })));
        preloadHighlighter({ themes, langs: langs.length > 0 ? langs : ["text"] })
          .catch((error) => console.warn("cmux diff highlighter preload failed", error));
      },
      onMetrics: (metrics) => dispatch({ type: "set-metrics", metrics }),
      onRename: (rename) => dispatch({ type: "rename-item", oldId: rename.oldId, newId: rename.newId }),
      onTreeSource: (source) => dispatch({ type: "set-tree-source", source }),
      parsePatchFiles,
      patchURL: payload.patchURL,
      processFile,
    }).catch((error) => {
      console.error("cmux diff viewer render failed", error);
      dispatch({ type: "set-status", status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }) });
    });
  }, [config, dispatch, label, latestState]);
}

function resolveDiffItemLanguage(item: DiffItem): void {
  const diff = item.fileDiff;
  if (diff == null) {
    return;
  }
  const lang = resolveDiffFileLanguage(fileName(diff, ""), diff.lang, getFiletypeFromFileName);
  diff.lang = lang;
}

function diffItemPreloadLanguages(item: DiffItem): string[] {
  const diff = item.fileDiff;
  if (diff == null) {
    return [];
  }
  return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff, getFiletypeFromFileName);
}

function mergeLanguages(current: string[], next: string[]): string[] {
  const languages = new Set(current);
  for (const language of next) {
    if (language.trim().length > 0) {
      languages.add(language);
    }
  }
  return Array.from(languages);
}

function isStatusOnlyPayload(payload: any): boolean {
  return payload?.pendingReplacement === true ||
    (typeof payload?.statusMessage === "string" && payload.statusMessage.length > 0);
}

function usePendingReplacement(payload: any, label: DiffViewerLabelResolver, dispatch: React.Dispatch<AppAction>) {
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
      fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" })
        .then(async (response) => {
          if (!response.ok) {
            throw new Error("replacement failed");
          }
          const text = await response.text();
          if (!text.includes("data-cmux-diff-pending=\"true\"")) {
            window.location.reload();
          }
        })
        .catch((error) => {
          document.documentElement.dataset.cmuxDiffWait = "failed";
          dispatch({ type: "set-status", status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }) });
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
  }, [dispatch, label, payload]);
}

function usePageDataAttributes(state: AppState) {
  useEffect(() => {
    document.body.dataset.filesHidden = state.filesVisible ? "false" : "true";
    document.body.dataset.loading = state.status.loading ? "true" : "false";
    document.documentElement.dataset.layout = state.options.layout;
    document.documentElement.dataset.wordWrap = String(state.options.wordWrap);
    document.documentElement.dataset.diffIndicators = state.options.diffIndicators;
    if (state.metrics) {
      document.body.dataset.streamFileCount = String(state.metrics.fileCount ?? state.items.length);
      document.body.dataset.streamRenderableFileCount = String(state.metrics.renderableFileCount ?? state.items.length);
      document.body.dataset.streamFlushCount = String(state.metrics.flushCount ?? 0);
      document.body.dataset.streamMaxBatchSize = String(state.metrics.maxBatchSize ?? 0);
      document.body.dataset.streamTreeRefreshCount = String(state.metrics.treeRefreshCount ?? 0);
      if (Number.isFinite(state.metrics.completedAt) && state.metrics.completedAt > 0) {
        document.body.dataset.streamElapsedMs = String(Math.round(state.metrics.completedAt - state.metrics.startedAt));
      }
    }
    applyDiffViewerStatusToDocument(state.status);
  }, [state]);
}

function useNativeViewerNavigation(
  viewerRef: React.MutableRefObject<HTMLDivElement | null>,
  dispatch: React.Dispatch<AppAction>,
  onJumpAdjacentFile: (direction: -1 | 1) => void,
) {
  useEffect(() => {
    window.__cmuxPerformDiffViewerNavigationAction = (action: string) => {
      const viewer = viewerRef.current;
      if (viewer && CmuxViewerNavigation.performAction(action, viewer)) {
        return true;
      }
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
  }, [dispatch, onJumpAdjacentFile, viewerRef]);
}

function useOptionsDismiss(optionsOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!optionsOpen) {
      return;
    }
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest("#toolbar")) {
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

function scrollTargetForItem(itemId: string, items: DiffItem[]): string {
  if (items.some((item) => item.id === itemId)) {
    return itemId;
  }
  return items[0]?.id ?? "";
}

export function adjacentItemId(activeItemId: string, items: DiffItem[], direction: -1 | 1): string {
  if (items.length === 0) {
    return "";
  }
  const currentIndex = items.findIndex((item) => item.id === activeItemId);
  if (currentIndex < 0) {
    return direction > 0 ? items[0].id : items[items.length - 1].id;
  }
  const targetIndex = currentIndex + direction;
  return targetIndex >= 0 && targetIndex < items.length ? items[targetIndex].id : "";
}

export function visibleItemId(
  items: DiffItem[],
  scrollTop: number,
  getTopForItem: (itemId: string) => number | undefined,
): string {
  let low = 0;
  let high = items.length - 1;
  let visibleIndex = items.length > 0 ? 0 : -1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const top = getTopForItem(items[middle].id);
    if (top != null && top <= scrollTop + 1) {
      visibleIndex = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return visibleIndex >= 0 ? items[visibleIndex].id : "";
}

function getInitialFileTreeRowCount(): number {
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return 25;
  }
  return Math.min(96, Math.max(25, Math.ceil(viewportHeight / 24)));
}
