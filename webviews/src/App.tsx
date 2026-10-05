import { CodeView, WorkerPoolContextProvider, type CodeViewHandle, useWorkerPool } from "@pierre/diffs/react";
import { parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import type { SelectedLineRange } from "@pierre/diffs";
import { FileTree, useFileTree } from "@pierre/trees/react";
import { preparePresortedFileTreeInput } from "@pierre/trees";
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
import { BranchBasePicker, branchPickerStateKey, type BranchPickerPayload } from "./BranchBasePicker";
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
import type { CommentDraft, DiffCommentRecord, DiffCommentSide } from "./comments/types";
import { useCommentsBootstrap } from "./comments/useCommentsBootstrap";
import { deferredDiffReason, type DeferredDiffReason } from "./deferred-diffs";
import { resolveDiffFileLanguage, resolveDiffPreloadLanguages } from "./diff-language";
import {
  fileName,
  fileStats,
  type DiffItem,
  type FileTreeSource,
  type StreamMetrics,
  streamPatch,
} from "./diff-stream";
import { DiffHeaderMetadata } from "./diff-metadata";
import { collapsedFileKey, withCollapsedFile } from "./collapsed-files";
import { treeFileActivation, treeFileRowPath } from "./file-activation";
import { computedTranslateX, createFilesPanelMotion, type FilesPanelMotion } from "./files-panel-motion";
import { DEFERRED_PATCH_KEY, hydrateDeferredFileDiff } from "./deferred-parse";
import { isHeaderToggleKey, shouldToggleFromHeaderClick, type HeaderPress } from "./file-header-toggle";
import { FileIcon } from "./file-icons";
import { defaultDiffFileFilter, filterDiffItems, isDiffFileFilterActive, type DiffFileFilter } from "./file-filter";
import { planPierreFileTreeRefresh, selectPierreFileTreePath } from "./file-tree-refresh";
import {
  createTextMeasure,
  diffStatSpriteSheet,
  fileTreeStatsDecoration,
  type FileTreeStatsDecoration,
  type MeasureText,
} from "./file-tree-stats";
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
import { FileMenuButton, FloatingToolbar, JumpToFilePalette, SourceMenu, ViewMenuButton } from "./DiffToolbar";
import {
  diffLineTotals,
  NO_HOST_CAPABILITIES,
  overflowMenuItems,
  sourceMenuModel,
  toolbarPillButtons,
  UNCOMMITTED_BASE_REF,
  type OverflowMenuItemId,
  type PillButtonId,
  type SourceTarget,
} from "./toolbar-model";
import {
  type ViewedChange,
  type ViewedFileEntry,
  type ViewedFileState,
  type ViewedScope,
  type ViewedSession,
  applyLoadedViewed,
  beginViewedLoad,
  loadViewedFiles,
  persistViewedChange,
  recordViewedChange,
  toggleViewedItem,
  viewedScopeFor,
  viewedScopeKey,
  viewedScopeKeyRepoRoot,
  viewedStateOfItem,
} from "./viewed-files";
import { buildHunkAnchors, nextHunkIndex } from "./viewer-hunks";
import {
  loadViewerPrefs,
  readLocalViewerPrefs,
  sanitizeViewerPrefs,
  saveViewerPrefs,
  type ViewerPrefs,
} from "./viewer-prefs";
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

type ConfigProps = {
  config: DiffViewerConfig;
  initialStatus: DiffViewerStatus;
};

/** A session the host opened for the viewer (branchChange answers `sessionOpened`). */
type AdoptedDiffSession = { session: SessionOpened; capabilityToken: string };

/** Switches the viewer to `source`: opens a session for it, or adopts `opened` when the host
 * already opened one. */
type SelectSessionSource = (source: DiffSource, opened?: AdoptedDiffSession) => void;

type ActiveDiffSession = {
  capabilityToken: string;
  sessionId: string;
};

const registeredCustomThemeNames = new Set<string>();
const pendingSessionID = "00000000-0000-0000-0000-000000000000";

type AppState = {
  activeItemId: string;
  activeTreePath: string;
  /** Files collapsed from their header caret, as `collapsedFileKey`s (persisted). */
  collapsedFiles: string[];
  comments: DiffCommentRecord[];
  copyFeedback: string;
  draft: CommentDraft | null;
  /** Path, status, and hide-viewed filter; hides diff sections and tree rows. */
  fileFilter: DiffFileFilter;
  fileSearchOpen: boolean;
  fileSearchRequest: number;
  filesWidth: number;
  filesVisible: boolean;
  findOpen: boolean;
  findQuery: string;
  findRequest: number;
  /** Paths the sidecar marked generated (`.gitattributes`) for this session. */
  generatedPaths: string[];
  items: DiffItem[];
  languages: string[];
  metrics: StreamMetrics | null;
  options: DiffViewerOptions;
  optionsOpen: boolean;
  /** Bumped by a soft refresh so the render effect re-streams in place. */
  renderGeneration: number;
  status: DiffViewerStatus;
  treeSource: FileTreeSource | null;
  /** Persisted "Viewed" entries for `viewedScopeKey`, keyed by file path. */
  viewedByPath: Map<string, ViewedFileEntry>;
  /** Toggles made in this scope; they win over a later stored-marks reply. */
  viewedLocalEdits: Map<string, ViewedFileEntry | null>;
  viewedScopeKey: string;
};

type AppAction =
  | { type: "append-items"; items: DiffItem[] }
  | { type: "relanguage-items" }
  | { type: "apply-persisted-options"; prefs: ViewerPrefs; allowLayout: boolean }
  | { type: "apply-viewed"; items: DiffItem[]; change: ViewedChange }
  | { type: "begin-viewed-load"; scopeKey: string }
  | { type: "expand-item"; itemId: string }
  | { type: "hydrate-item"; itemId: string; fileDiff: any }
  | { type: "set-item-collapsed"; itemId: string; collapsed: boolean; collapsedFiles: string[] }
  | { type: "replace-viewed"; scopeKey: string; entries: ViewedFileEntry[] }
  | { type: "set-file-filter"; filter: Partial<DiffFileFilter> }
  | { type: "set-generated-paths"; paths: string[] }
  | { type: "refresh"; status: DiffViewerStatus }
  | { type: "reset-diff"; status: DiffViewerStatus }
  | { type: "remove-comment"; id: string }
  | { type: "rename-item"; oldId: string; newId: string }
  | { type: "set-active-item"; itemId: string; treePath?: string }
  | { type: "replace-comments"; comments: DiffCommentRecord[] }
  | { type: "set-copy-feedback"; message: string }
  | { type: "set-draft"; draft: CommentDraft | null }
  | { type: "set-file-search-open"; open: boolean }
  | { type: "request-file-search" }
  | { type: "set-find-open"; open: boolean }
  | { type: "set-find-query"; query: string }
  | { type: "request-find" }
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
type DiffViewerLayout = DiffViewerOptions["layout"];

function initialAppState(config: DiffViewerConfig, initialStatus: DiffViewerStatus): AppState {
  const payload = config.payload ?? {};
  // Display toggles persisted by previous sessions are baked into the payload
  // by the CLI so first paint matches; the viewerPrefs bridge re-syncs them
  // live after boot. Layout is owned by payload.layout/layoutSource.
  const {
    layout: _seededLayout,
    collapsedFiles: seededCollapsedFiles,
    ...seededOptions
  } = sanitizeViewerPrefs(payload.viewerOptions);
  return {
    activeItemId: "",
    activeTreePath: "",
    collapsedFiles: seededCollapsedFiles ?? readLocalViewerPrefs().collapsedFiles ?? [],
    comments: [],
    copyFeedback: "",
    draft: null,
    fileFilter: defaultDiffFileFilter(),
    fileSearchOpen: false,
    fileSearchRequest: 0,
    filesWidth: 252,
    filesVisible: true,
    findOpen: false,
    findQuery: "",
    findRequest: 0,
    generatedPaths: [],
    items: [],
    languages: ["text"],
    metrics: null,
    options: {
      collapsed: false,
      diffIndicators: "bars",
      expandUnchanged: false,
      lineNumbers: true,
      showBackgrounds: true,
      wordDiffs: false,
      wordWrap: false,
      ...seededOptions,
      layout: initialDiffViewerLayout(payload),
    } as DiffViewerOptions,
    optionsOpen: false,
    renderGeneration: 0,
    status: initialStatus,
    treeSource: null,
    viewedByPath: new Map(),
    viewedLocalEdits: new Map(),
    viewedScopeKey: "",
  };
}

/**
 * Generated and large files start collapsed (GitHub "Load diff" behavior),
 * and a file whose stored viewed fingerprint still matches starts collapsed
 * too, as does a file the user collapsed from its header caret.
 * `collapsed` is otherwise the session-wide collapse-all toggle.
 */
function prepareAppendedItem(item: DiffItem, state: AppState, generatedPaths: ReadonlySet<string>): DiffItem {
  const diff = item.fileDiff ?? {};
  const stats = fileStats(diff);
  const reason = deferredDiffReason({
    path: fileName(diff, ""),
    changedLines: stats.added + stats.deleted,
    patchBytes: typeof diff.cmuxPatchByteLength === "number" ? diff.cmuxPatchByteLength : 0,
    generatedPaths,
  });
  if (reason != null) {
    diff.cmuxDeferredReason = reason;
  }
  const viewed = viewedStateOfItem(item, state.viewedByPath) === "viewed";
  const userCollapsed = isUserCollapsed(item, state);
  return state.options.collapsed || reason != null || viewed || userCollapsed ? { ...item, collapsed: true } : item;
}

function itemCollapsedFileKey(item: DiffItem, scopeKey: string): string {
  return collapsedFileKey(viewedScopeKeyRepoRoot(scopeKey), fileName(item.fileDiff ?? {}, ""));
}

function isUserCollapsed(item: DiffItem, state: Pick<AppState, "collapsedFiles" | "viewedScopeKey">): boolean {
  return (
    state.collapsedFiles.length > 0 && state.collapsedFiles.includes(itemCollapsedFileKey(item, state.viewedScopeKey))
  );
}

function viewedSessionOf(state: AppState): ViewedSession {
  return { scopeKey: state.viewedScopeKey, viewedByPath: state.viewedByPath, localEdits: state.viewedLocalEdits };
}

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    case "apply-viewed": {
      const session = recordViewedChange(viewedSessionOf(state), action.change);
      return {
        ...state,
        items: action.items,
        viewedByPath: session.viewedByPath,
        viewedLocalEdits: session.localEdits,
      };
    }
    case "begin-viewed-load": {
      const session = beginViewedLoad(action.scopeKey);
      const scoped = { ...state, viewedScopeKey: session.scopeKey };
      return {
        ...scoped,
        // The repository is known now, so caret-collapsed files already
        // streamed for it collapse.
        items: state.items.map((item) =>
          !item.collapsed && isUserCollapsed(item, scoped)
            ? { ...item, collapsed: true, version: (item.version ?? 0) + 1 }
            : item,
        ),
        viewedByPath: session.viewedByPath,
        viewedLocalEdits: session.localEdits,
      };
    }
    case "set-item-collapsed":
      return {
        ...state,
        collapsedFiles: action.collapsedFiles,
        items: state.items.map((item) =>
          item.id === action.itemId && Boolean(item.collapsed) !== action.collapsed
            ? { ...item, collapsed: action.collapsed, version: (item.version ?? 0) + 1 }
            : item,
        ),
      };
    case "hydrate-item":
      return {
        ...state,
        items: state.items.map((item) =>
          item.id === action.itemId
            ? withCommentAnnotations(
                { ...item, fileDiff: action.fileDiff, version: (item.version ?? 0) + 1 },
                state.comments,
                state.draft,
              )
            : item,
        ),
      };
    case "expand-item":
      return {
        ...state,
        items: state.items.map((item) =>
          item.id === action.itemId ? { ...item, collapsed: false, version: (item.version ?? 0) + 1 } : item,
        ),
      };
    case "replace-viewed": {
      const session = applyLoadedViewed(viewedSessionOf(state), action.scopeKey, action.entries);
      if (session == null) {
        return state;
      }
      const { viewedByPath } = session;
      // Files already streamed collapse once their stored mark turns out to
      // still match, the same way a late-arriving batch would.
      const items = state.items.map((item) => {
        const viewed = viewedStateOfItem(item, viewedByPath) === "viewed";
        return viewed && !item.collapsed ? { ...item, collapsed: true, version: (item.version ?? 0) + 1 } : item;
      });
      return { ...state, items, viewedByPath };
    }
    case "set-file-filter":
      return { ...state, fileFilter: { ...state.fileFilter, ...action.filter } };
    case "set-generated-paths":
      return { ...state, generatedPaths: action.paths };
    case "apply-persisted-options": {
      const { layout, collapsedFiles, ...prefs } = action.prefs;
      const withCollapsed = { ...state, collapsedFiles: collapsedFiles ?? state.collapsedFiles };
      return {
        ...withCollapsed,
        // Files streamed before the stored preferences arrived collapse now.
        items: state.items.map((item) =>
          !item.collapsed && isUserCollapsed(item, withCollapsed)
            ? { ...item, collapsed: true, version: (item.version ?? 0) + 1 }
            : item,
        ),
        options: {
          ...state.options,
          ...prefs,
          ...(action.allowLayout && layout != null ? { layout } : {}),
        },
      };
    }
    case "refresh":
      return {
        ...state,
        activeItemId: "",
        activeTreePath: "",
        draft: null,
        generatedPaths: [],
        items: [],
        languages: ["text"],
        metrics: null,
        renderGeneration: state.renderGeneration + 1,
        status: action.status,
        treeSource: null,
      };
    case "append-items": {
      const generatedPaths = new Set(state.generatedPaths);
      const nextItems = action.items.map((item) => {
        resolveDiffItemLanguage(item);
        const annotated = withCommentAnnotations(item, state.comments, state.draft);
        return prepareAppendedItem(annotated, state, generatedPaths);
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
    case "relanguage-items": {
      const items = relanguagedItems(state.items);
      return items.every((item, index) => item === state.items[index])
        ? state
        : { ...state, items, languages: mergeLanguages(state.languages, items.flatMap(diffItemPreloadLanguages)) };
    }
    case "reset-diff":
      return {
        ...state,
        activeItemId: "",
        activeTreePath: "",
        draft: null,
        generatedPaths: [],
        items: [],
        languages: ["text"],
        metrics: null,
        status: action.status,
        treeSource: null,
      };
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
        draft: state.draft?.itemId === action.oldId ? { ...state.draft, itemId: action.newId } : state.draft,
        items: state.items.map((item) =>
          item.id === action.oldId || item.id === action.newId
            ? { ...item, id: action.newId, version: (item.version ?? 0) + 1 }
            : item,
        ),
      };
    case "set-active-item":
      return {
        ...state,
        activeItemId: action.itemId,
        activeTreePath: action.treePath ?? state.activeTreePath,
      };
    case "replace-comments":
      return {
        ...state,
        comments: action.comments,
        draft: null,
        items: applyCommentAnnotations(state.items, action.comments, null),
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
    case "set-find-open":
      // The query is kept when closing so reopening recovers the last search.
      return { ...state, findOpen: action.open };
    case "set-find-query":
      return { ...state, findQuery: action.query };
    case "request-find":
      return { ...state, findOpen: true, findRequest: state.findRequest + 1 };
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
      const nextPath = state.activeItemId
        ? (source.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath)
        : state.activeTreePath;
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

function initialDiffViewerLayout(payload: Record<string, any>): DiffViewerLayout {
  const payloadLayout = parseDiffViewerLayout(payload.layout);
  if (payload.layoutSource === "explicit" && payloadLayout) {
    return payloadLayout;
  }
  // The CLI bakes the globally persisted layout into the payload at generation
  // time; local storage only matters for pages opened outside cmux. The
  // viewerPrefs bridge re-syncs the live value right after boot.
  return readLocalViewerPrefs().layout ?? payloadLayout ?? "unified";
}

function parseDiffViewerLayout(value: unknown): DiffViewerLayout | null {
  return value === "split" || value === "unified" ? value : null;
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

/**
 * One file's header row, rendered into Pierre's custom header slot (the row
 * itself is Pierre's opaque sticky header): the language icon, the dim
 * directory and bright file name, the collapse caret, then the change counts
 * and the review controls. The whole bar is the collapse toggle
 * (file-header-toggle.ts); its controls keep their own actions.
 */
export function FileHeader({
  item,
  label,
  onCopyPath,
  onLoadDiff,
  onToggleCollapsed,
  onToggleViewed,
  viewedState,
}: {
  item: DiffItem;
  label: DiffViewerLabelResolver;
  /** The "..." menu's Copy path; the menu shows only that row when given. */
  onCopyPath?: (path: string) => void;
  onLoadDiff: () => void;
  onToggleCollapsed: () => void;
  onToggleViewed: () => void;
  viewedState: ViewedFileState;
}) {
  const fileDiff = item.fileDiff ?? {};
  const path = fileName(fileDiff, label("untitled"));
  const slash = path.lastIndexOf("/");
  const directory = slash >= 0 ? path.slice(0, slash + 1) : "";
  const baseName = path.slice(slash + 1);
  const previousPath = typeof fileDiff.prevName === "string" && fileDiff.prevName !== path ? fileDiff.prevName : null;
  const stats = fileStats(fileDiff);
  const collapsed = Boolean(item.collapsed);
  const caretLabel = (collapsed ? label("expandFile") : label("collapseFile")).replace("{file}", baseName);
  const press = useRef<HeaderPress | null>(null);
  return (
    // The bar holds its own buttons (Viewed, Load diff), which a <button>
    // cannot contain, so the toggle is a focusable element with the button role.
    <div
      className="file-header"
      data-collapsed={collapsed}
      data-change-type={fileDiff.type}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="button"
      tabIndex={0}
      aria-expanded={!collapsed}
      aria-label={caretLabel}
      onMouseDown={(event) => {
        press.current = event.button === 0 ? { x: event.clientX, y: event.clientY } : null;
      }}
      onClick={(event) => {
        const start = press.current;
        press.current = null;
        if (shouldToggleFromHeaderClick(event, start)) {
          onToggleCollapsed();
        }
      }}
      onKeyDown={(event) => {
        if (isHeaderToggleKey(event)) {
          event.preventDefault();
          onToggleCollapsed();
        }
      }}
    >
      <FileIcon path={path} />
      <span className="file-header-path selectable" title={previousPath == null ? path : `${previousPath} → ${path}`}>
        {previousPath != null ? (
          <span className="file-header-previous">
            <bdi>{previousPath}</bdi>
            <span aria-hidden="true"> → </span>
          </span>
        ) : null}
        {directory !== "" ? (
          <span className="file-header-directory">
            <bdi>{directory}</bdi>
          </span>
        ) : null}
        <span className="file-header-name">{baseName}</span>
      </span>
      <span className="file-header-caret" aria-hidden="true">
        <Icon name="chevronDown" />
      </span>
      <span className="file-header-spacer" />
      <DiffHeaderMetadata fileDiff={fileDiff} label={label} />
      <span className="file-header-stats" aria-label={label("diffStats")}>
        <span className="file-header-additions" title={label("additions")}>
          +{stats.added}
        </span>
        <span className="file-header-deletions" title={label("deletions")}>
          -{stats.deleted}
        </span>
      </span>
      <FileReviewControls
        item={item}
        label={label}
        onLoadDiff={onLoadDiff}
        onToggleViewed={onToggleViewed}
        viewedState={viewedState}
      />
      <FileMenuButton
        label={label("fileActions").replace("{file}", baseName)}
        items={[
          {
            id: "viewed",
            icon: viewedState === "viewed" ? "eyeClosed" : "eye",
            label: viewedState === "viewed" ? label("markNotViewed") : label("markViewed"),
            onChoose: onToggleViewed,
          },
          ...(onCopyPath
            ? [
                {
                  id: "copy-path",
                  icon: "clipboard" as const,
                  label: label("copyFilePath"),
                  onChoose: () => onCopyPath(path),
                },
              ]
            : []),
        ]}
      />
    </div>
  );
}

/**
 * Per-file review controls rendered at the end of the file header: the
 * "Viewed" checkbox with its "changed since viewed" badge, and the generated /
 * large badge with a "Load diff" button while such a file is still collapsed.
 * Clicks stop propagating so they never reach the header row's own handlers.
 */
function FileReviewControls({
  item,
  label,
  onLoadDiff,
  onToggleViewed,
  viewedState,
}: {
  item: DiffItem;
  label: DiffViewerLabelResolver;
  onLoadDiff: () => void;
  onToggleViewed: () => void;
  viewedState: ViewedFileState;
}) {
  const reason = item.fileDiff?.cmuxDeferredReason as DeferredDiffReason | undefined;
  const viewed = viewedState === "viewed";
  return (
    <span className="file-review-controls" data-viewed-state={viewedState}>
      {reason != null ? (
        <span className="file-review-badge" data-deferred-reason={reason}>
          {reason === "generated" ? label("generatedFile") : label("largeDiff")}
        </span>
      ) : null}
      {reason != null && item.collapsed ? (
        <button
          type="button"
          className="file-review-load"
          title={reason === "generated" ? label("generatedFile") : label("largeDiff")}
          onClick={(event) => {
            event.stopPropagation();
            onLoadDiff();
          }}
        >
          {label("loadDiff")}
        </button>
      ) : null}
      {viewedState === "changed" ? (
        <span className="file-review-badge" data-changed-since-viewed="true">
          {label("changedSinceViewed")}
        </span>
      ) : null}
      <button
        type="button"
        className="file-review-viewed"
        aria-pressed={viewed}
        aria-label={label("viewed")}
        title={viewed ? label("markNotViewed") : label("markViewed")}
        onClick={(event) => {
          event.stopPropagation();
          onToggleViewed();
        }}
      >
        {/* The classic bar's eye: dim until the file is viewed. */}
        <span className="file-review-eye" aria-hidden="true">
          <Icon name="viewedEye" />
        </span>
      </button>
    </span>
  );
}

/**
 * The tree source narrowed to the visible (filtered) items. With no active
 * filter the streamed source passes through unchanged so incremental tree
 * appends keep working; a filtered source resets the tree instead.
 */
function filteredFileTreeSource(
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
  activeSessionSource,
  config,
  label,
  onJump,
  onNavigate,
  onSelectSessionSource,
  pill,
  rememberedBranch,
  state,
  transport,
  visibleItems,
}: {
  activeSessionSource: DiffSource | null;
  config: DiffViewerConfig;
  label: DiffViewerLabelResolver;
  onJump: (itemId: string) => void;
  onNavigate: (url: string) => void;
  onSelectSessionSource: SelectSessionSource;
  /** The floating toolbar pill, at the right end of the bar above the files sidebar. */
  pill: React.ReactNode;
  rememberedBranch: Extract<DiffSource, { kind: "branch" }> | null;
  state: AppState;
  transport: DiffTransport | null;
  visibleItems: DiffItem[];
}) {
  const payload = config.payload ?? {};
  return (
    <header id="toolbar">
      <SourceControls
        activeSessionSource={activeSessionSource}
        items={state.items}
        label={label}
        onNavigate={onNavigate}
        onSelectSessionSource={onSelectSessionSource}
        payload={payload}
        rememberedBranch={rememberedBranch}
        transport={transport}
      >
        <JumpToFilePalette items={visibleItems} label={label} onJump={onJump} />
      </SourceControls>
      {pill}
      <span id="copy-feedback" className="visually-hidden" aria-live="polite">
        {state.copyFeedback}
      </span>
    </header>
  );
}

/**
 * The toolbar pill (top right, above the files sidebar) and its "..." menu: the
 * menu rows the reference viewer has, then the remaining view options.
 */
function DiffPill({
  dispatch,
  externalURL,
  label,
  onCopyGitApply,
  onReload,
  onSetLayout,
  onSetOption,
  state,
}: {
  dispatch: React.Dispatch<AppAction>;
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onReload: () => void;
  onSetLayout: (layout: DiffViewerLayout) => void;
  onSetOption: (key: keyof DiffViewerOptions, value: any) => void;
  state: AppState;
}) {
  const onButton = (id: PillButtonId) => {
    switch (id) {
      case "options":
        dispatch({ type: "set-options-open", open: !state.optionsOpen });
        return;
      case "find":
        dispatch(state.findOpen ? { type: "set-find-open", open: false } : { type: "request-find" });
        return;
      case "refresh":
        onReload();
        return;
      case "wrap":
        onSetOption("wordWrap", !state.options.wordWrap);
        return;
      case "expand":
        onSetOption("collapsed", !state.options.collapsed);
        return;
      case "layout":
        onSetLayout(state.options.layout === "split" ? "unified" : "split");
        return;
      case "files":
        dispatch({ type: "set-files-visible", visible: !state.filesVisible });
        return;
    }
  };
  const onMenuItem = (id: OverflowMenuItemId) => {
    switch (id) {
      case "load-full-files":
        onSetOption("expandUnchanged", !state.options.expandUnchanged);
        return;
      case "word-diffs":
        onSetOption("wordDiffs", !state.options.wordDiffs);
        return;
      case "copy-git-apply":
        onCopyGitApply();
        return;
      default:
        // Rich preview, Hide white space and Hide imports have nothing the viewer
        // can apply yet; their rows are unavailable (NO_HOST_CAPABILITIES).
        return;
    }
  };
  return (
    <FloatingToolbar
      buttons={toolbarPillButtons(state)}
      label={label}
      menuItems={overflowMenuItems(state.options, NO_HOST_CAPABILITIES)}
      menuOpen={state.optionsOpen}
      onButton={onButton}
      onCloseMenu={() => dispatch({ type: "set-options-open", open: false })}
      onMenuItem={onMenuItem}
      viewMenu={
        <ViewOptionsMenuRows
          externalURL={externalURL}
          label={label}
          onSetOption={onSetOption}
          onToggleHideViewed={() =>
            dispatch({ type: "set-file-filter", filter: { hideViewed: !state.fileFilter.hideViewed } })
          }
          state={state}
        />
      }
    />
  );
}

/** View options the reference menu does not list, kept under a separator. */
function ViewOptionsMenuRows({
  externalURL,
  label,
  onSetOption,
  onToggleHideViewed,
  state,
}: {
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onSetOption: (key: keyof DiffViewerOptions, value: any) => void;
  onToggleHideViewed: () => void;
  state: AppState;
}) {
  return (
    <>
      <hr className="menu-separator" />
      {externalURL ? (
        <ViewMenuButton
          icon="external"
          label={label("openSourceURL")}
          onClick={() => window.open(externalURL, "_blank", "noreferrer")}
        />
      ) : null}
      <ViewMenuButton
        checked={state.fileFilter.hideViewed}
        icon={state.fileFilter.hideViewed ? "eyeClosed" : "eye"}
        id="hide-viewed-toggle"
        label={label("hideViewedFiles")}
        onClick={onToggleHideViewed}
      />
      <ViewMenuButton
        checked={state.options.showBackgrounds}
        icon="background"
        label={state.options.showBackgrounds ? label("hideBackgrounds") : label("showBackgrounds")}
        onClick={() => onSetOption("showBackgrounds", !state.options.showBackgrounds)}
      />
      <ViewMenuButton
        checked={state.options.lineNumbers}
        icon="numbers"
        label={state.options.lineNumbers ? label("hideLineNumbers") : label("showLineNumbers")}
        onClick={() => onSetOption("lineNumbers", !state.options.lineNumbers)}
      />
      <div className="menu-item menu-segment">
        <Icon name="bars" />
        <span className="menu-label">{label("indicatorStyle")}</span>
        <span className="menu-segment-controls">
          {[
            { value: "bars", icon: "bars", label: label("bars") },
            { value: "classic", icon: "classic", label: label("classic") },
            { value: "none", icon: "none", label: label("none") },
          ].map((option) => (
            <button
              key={option.value}
              type="button"
              className="segment-button"
              title={option.label}
              aria-label={option.label}
              aria-pressed={state.options.diffIndicators === option.value}
              onClick={() => onSetOption("diffIndicators", option.value)}
            >
              <Icon name={option.icon as IconName} />
            </button>
          ))}
        </span>
      </div>
    </>
  );
}

function SourceControls({
  activeSessionSource,
  children,
  items,
  label,
  onNavigate,
  onSelectSessionSource,
  payload,
  rememberedBranch,
  transport,
}: {
  activeSessionSource: DiffSource | null;
  /** Controls after the source and base pills (the jump-to-file button). */
  children?: React.ReactNode;
  items: DiffItem[];
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  onSelectSessionSource: SelectSessionSource;
  payload: any;
  rememberedBranch: Extract<DiffSource, { kind: "branch" }> | null;
  transport: DiffTransport | null;
}) {
  const repoRoot =
    diffSourceRepoRoot(activeSessionSource) ??
    (typeof payload.repoRoot === "string" && payload.repoRoot !== "" ? payload.repoRoot : null);
  const sourceModel = sourceMenuModel({
    sourceOptions: payload.sourceOptions,
    repoRoot,
    activeSource: activeSessionSource,
    rememberedBranch,
    branchBaseRef: typeof payload.branchBaseRef === "string" ? payload.branchBaseRef : null,
    typedTransport: transport != null && activeSessionSource != null,
    isValidSource: validDiffSource,
  });
  const showSourceMenu = sourceModel.selected != null || sourceModel.sections.flat().some((entry) => entry.target);
  const totals = diffLineTotals(items);
  const selectSource = (target: SourceTarget) => {
    if (target.kind === "url") {
      onNavigate(target.url);
      return;
    }
    onSelectSessionSource(sourceSelectionWithActiveRepo(target.source, activeSessionSource));
  };
  return (
    <div className="toolbar-left flex min-w-0 items-center gap-1.5">
      {showSourceMenu ? (
        <SourceMenu
          additions={totals.additions}
          deletions={totals.deletions}
          label={label}
          model={sourceModel}
          onSelect={selectSource}
        />
      ) : null}
      {/* The repo select is ALWAYS rendered when the host lists several
          repositories. It shrinks and ellipsizes in place. */}
      {activeSessionSource?.kind !== "patch" ? (
        <NavigationSelect
          ariaLabel={label("repoPath")}
          fallbackValue={payload.repoRoot ?? ""}
          id="repo-select"
          options={payload.repoOptions}
          onNavigate={onNavigate}
          onSelectSessionSource={(source) =>
            onSelectSessionSource(repoSelectionWithActiveSource(source, activeSessionSource))
          }
          selectedOptionTitle
          selectedValue={diffSourceRepoRoot(activeSessionSource)}
        />
      ) : null}
      {sourceModel.selected?.id === "uncommitted" ? null : (
        <BaseControl
          activeSessionSource={activeSessionSource}
          label={label}
          onNavigate={onNavigate}
          onSelectSessionSource={onSelectSessionSource}
          payload={payload}
          transport={transport}
        />
      )}
      {children}
    </div>
  );
}

/**
 * Renders the searchable Base button+popover when the backend supplies
 * `payload.branchPicker` (FROZEN CONTRACT). Falls back to the legacy capped
 * `<select>` for older backends that only send `payload.baseOptions`.
 */
function BaseControl({
  activeSessionSource,
  label,
  onNavigate,
  onSelectSessionSource,
  payload,
  transport,
}: {
  activeSessionSource: DiffSource | null;
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  onSelectSessionSource: SelectSessionSource;
  payload: any;
  transport: DiffTransport | null;
}) {
  if (activeSessionSource?.kind === "branch" && transport) {
    const typedPicker: BranchPickerPayload = {
      repoRoot: activeSessionSource.repoRoot,
      capabilityToken: payload.capabilityToken,
      // The sidecar does not report the checked-out branch name; a host that
      // knows it can send `payload.headRef`.
      headRef: typeof payload.headRef === "string" && payload.headRef !== "" ? payload.headRef : "HEAD",
      currentRef: activeSessionSource.baseRef ?? "",
      currentReason: "",
      confidence: "high",
      aheadBehind: null,
      refsURL: "typed://branch-list",
      regenerateURLTemplate: "typed://branch-change/{ref}",
    };
    return (
      <BranchBasePicker
        key={branchPickerStateKey(typedPicker)}
        label={label}
        onNavigate={onNavigate}
        onSelectBranchBase={(baseRef) =>
          onSelectSessionSource({
            kind: "branch",
            repoRoot: activeSessionSource.repoRoot,
            baseRef,
          })
        }
        picker={typedPicker}
        transport={transport}
      />
    );
  }
  const picker = resolveBranchPicker(payload);
  if (picker) {
    return (
      <BranchBasePicker
        key={branchPickerStateKey(picker)}
        label={label}
        onNavigate={onNavigate}
        onBranchSessionOpened={(session) =>
          onSelectSessionSource(session.source, { session, capabilityToken: picker.capabilityToken ?? "" })
        }
        picker={picker}
        transport={transport}
      />
    );
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
    typeof value.refsURL === "string" &&
    value.refsURL !== "" &&
    typeof value.regenerateURLTemplate === "string" &&
    value.regenerateURLTemplate !== "" &&
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
    refsURL:
      "data:application/json," +
      encodeURIComponent(
        JSON.stringify({
          groups: [
            {
              id: "suggested",
              label: "Suggested",
              rows: [
                { ref: "main", label: "main", reason: "fork point", confidence: "low", current: true },
                { ref: "origin/main", label: "origin/main", reason: "PR base" },
              ],
            },
            {
              id: "worktrees",
              label: "Worktrees",
              rows: [{ ref: "feat-x", label: "feat-x", worktreeDir: "../worktrees/feat-x" }],
            },
            {
              id: "branches",
              label: "Branches",
              rows: [
                { ref: "develop", label: "develop", secondary: "2 days ago" },
                { ref: "release/1.0", label: "release/1.0", secondary: "1 week ago" },
              ],
            },
            // Large remotes group so the render cap (top N + "... more") is
            // exercisable in DEV without a wired backend.
            {
              id: "remotes",
              label: "Remotes",
              rows: Array.from({ length: 2304 }, (_value, index) => ({
                ref: `origin/feature-${index}`,
                label: `origin/feature-${index}`,
              })),
            },
          ],
        }),
      ),
    regenerateURLTemplate: "about:blank#base={ref}",
  };
}

function NavigationSelect({
  ariaLabel,
  fallbackValue,
  id,
  onNavigate,
  onSelectSessionSource,
  options,
  selectedOptionTitle = false,
  selectedValue,
}: {
  ariaLabel: string;
  fallbackValue: string;
  id: string;
  onNavigate: (url: string) => void;
  onSelectSessionSource?: (source: DiffSource) => void;
  options: any[] | undefined;
  selectedOptionTitle?: boolean;
  selectedValue?: string | null;
}) {
  if (!Array.isArray(options) || options.length < 2) {
    return null;
  }
  const selected =
    options.find((option) => option.value === selectedValue) ??
    options.find((option) => option.selected) ??
    options.find((option) => !option.disabled);
  const selectedTitle = selectedOptionTitle
    ? typeof selected?.message === "string" && selected.message.trim() !== ""
      ? selected.message
      : String(selected?.value ?? fallbackValue).trim() || ariaLabel
    : ariaLabel;
  return (
    <select
      id={id}
      aria-label={ariaLabel}
      value={selected?.value ?? fallbackValue}
      title={selectedTitle}
      onChange={(event) => {
        const next = options.find((option) => option.value === event.currentTarget.value);
        if (validDiffSource(next?.sessionSource) && onSelectSessionSource) {
          onSelectSessionSource(next.sessionSource);
          return;
        }
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
          disabled={option.disabled || (!option.url && !validDiffSource(option.sessionSource))}
          title={option.message}
        >
          {option.label}
        </option>
      ))}
    </select>
  );
}

function FilesSidebar({
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

function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div
          key={`${width}-${index}`}
          className="grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]"
        >
          <span className="size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span
            className="h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70"
            style={{ width: index % 2 === 0 ? "34px" : "24px" }}
          />
        </div>
      ))}
    </div>
  );
}

function LoadingDiffSkeleton() {
  return (
    <div
      className="diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3"
      aria-hidden="true"
    >
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

/// Re-detects every file's language when the host installs new user languages or overrides.
function useDiffLanguageChanges(dispatch: React.Dispatch<AppAction>): void {
  useEffect(() => diffLanguages.subscribe(() => dispatch({ type: "relanguage-items" })), [dispatch]);
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
    workerPool
      .setRenderOptions(highlighterOptions)
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
  return (
    // `langs` only seed the pool at creation; the pool loads each file's grammar with its task,
    // so a newly seen language must not force a full re-render.
    previous?.lineDiffType === next.lineDiffType &&
    previous?.maxLineDiffLength === next.maxLineDiffLength &&
    previous?.preferredHighlighter === next.preferredHighlighter &&
    sameThemeOption(previous?.theme, next.theme) &&
    previous?.tokenizeMaxLineLength === next.tokenizeMaxLineLength &&
    previous?.useTokenTransformer === next.useTokenTransformer
  );
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
  return (
    (previous as { dark?: string }).dark === (next as { dark?: string }).dark &&
    (previous as { light?: string }).light === (next as { light?: string }).light
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

function closeDiffSession(transport: DiffTransport, session: ActiveDiffSession): Promise<void> {
  return transport.request({ method: "sessionClose", params: session }).then(
    () => {},
    () => {},
  );
}

function diffSessionRequest(
  payload: any,
  transport: DiffTransport | null,
  overrideSource?: DiffSource | null,
): {
  source: DiffSource;
  capabilityToken: string;
} | null {
  if (!transport || typeof payload?.capabilityToken !== "string") {
    return null;
  }
  const source = overrideSource ?? payload.sessionSource;
  if (!validDiffSource(source)) {
    return null;
  }
  return { source, capabilityToken: payload.capabilityToken };
}

function validDiffSource(value: unknown): value is DiffSource {
  if (!value || typeof value !== "object" || typeof (value as { kind?: unknown }).kind !== "string") {
    return false;
  }
  const source = value as { kind: string; repoRoot?: unknown; path?: unknown; baseRef?: unknown };
  if (source.kind === "patch") {
    return typeof source.path === "string";
  }
  if (source.kind === "unstaged" || source.kind === "staged") {
    return typeof source.repoRoot === "string";
  }
  return (
    source.kind === "branch" &&
    typeof source.repoRoot === "string" &&
    (source.baseRef == null || typeof source.baseRef === "string")
  );
}

function diffSourceRepoRoot(source: DiffSource | null): string | null {
  return source && "repoRoot" in source ? source.repoRoot : null;
}

function sourceSelectionWithActiveRepo(source: DiffSource, active: DiffSource | null): DiffSource {
  if (source.kind === "patch") {
    return source;
  }
  const activeRepo = diffSourceRepoRoot(active);
  if (!activeRepo) {
    return source;
  }
  if (source.kind === "branch") {
    return source.repoRoot === activeRepo
      ? { ...source, repoRoot: activeRepo }
      : { kind: "branch", repoRoot: activeRepo };
  }
  return { ...source, repoRoot: activeRepo };
}

function repoSelectionWithActiveSource(source: DiffSource, active: DiffSource | null): DiffSource {
  const repoRoot = diffSourceRepoRoot(source);
  if (!repoRoot || !active || active.kind === "patch") {
    return source;
  }
  if (active.kind === "branch") {
    return active.repoRoot === repoRoot ? { ...active, repoRoot } : { kind: "branch", repoRoot };
  }
  return { ...active, repoRoot };
}

/// Sets `fileDiff.lang` to the detected language. The language the parser chose and the
/// worker cache key are kept beside it, so a later language change (the host pushed new user
/// languages) detects from the same input and never reads a cached render of the old language.
function resolveDiffItemLanguage(item: DiffItem): void {
  const diff = item.fileDiff;
  if (diff == null) {
    return;
  }
  if (!("cmuxParsedLanguage" in diff)) {
    diff.cmuxParsedLanguage = diff.lang;
    diff.cmuxBaseCacheKey = diff.cacheKey;
  }
  const lang = resolveDiffFileLanguage(fileName(diff, ""), diff.cmuxParsedLanguage, diff);
  diff.lang = lang;
  if (typeof diff.cmuxBaseCacheKey === "string") {
    diff.cacheKey = `${diff.cmuxBaseCacheKey}:${lang}`;
  }
}

/// The items whose language changed under the current language registry, as new objects.
function relanguagedItems(items: DiffItem[]): DiffItem[] {
  return items.map((item) => {
    const diff = item.fileDiff;
    if (diff == null) {
      return item;
    }
    const next = { ...item, fileDiff: { ...diff } };
    resolveDiffItemLanguage(next);
    return next.fileDiff.lang === diff.lang ? item : { ...next, version: (item.version ?? 0) + 1 };
  });
}

function diffItemPreloadLanguages(item: DiffItem): string[] {
  const diff = item.fileDiff;
  if (diff == null) {
    return [];
  }
  return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff);
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

function isStatusOnlyPayload(
  payload: any,
  transport: DiffTransport | null = null,
  sessionSource: DiffSource | null = null,
): boolean {
  if (payload?.pendingReplacement === true) {
    return diffSessionRequest(payload, transport, sessionSource) == null;
  }
  return typeof payload?.statusMessage === "string" && payload.statusMessage.length > 0;
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
  }, [dispatch, findBridgeRef, onJumpAdjacentFile, onJumpAdjacentHunk, onToggleViewed, viewerRef]);
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

/**
 * Applies `update` and, when it collapses `collapsingItemId` while that file's
 * header is stuck at the top of the viewer (the viewer is scrolled into the
 * file's body), scrolls so the collapsed header stays the top row. Without
 * this the viewer keeps its line anchor into content that no longer exists
 * and lands a few pixels into the previous file. `update` is flushed first
 * so the code view lays out the collapsed item before the scroll resolves.
 */
export function keepStuckHeaderInView(
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>,
  collapsingItemId: string | null,
  update: () => void,
): void {
  const instance = collapsingItemId == null ? null : codeViewRef.current?.getInstance();
  const top = instance == null ? undefined : instance.getTopForItem(collapsingItemId!);
  const stuck = instance != null && typeof top === "number" && top < instance.getScrollTop();
  if (!stuck) {
    update();
    return;
  }
  flushSync(update);
  codeViewRef.current?.scrollTo({ type: "item", id: collapsingItemId!, align: "start", behavior: "instant" });
}

const plainTextItems = new WeakMap<DiffItem, DiffItem>();

/**
 * A collapsed file shows only its header, but @pierre/diffs still sends a
 * mounted collapsed file to the highlight workers (FileDiff.render runs the
 * hunks renderer with an empty range, which queues the whole file). On a
 * large diff that put five collapsed 20,000-line files ahead of the visible
 * file in the worker queue. Presenting a collapsed file as plain text
 * (`lang: "text"`, Pierre's own no-highlight path, with its own cache key)
 * keeps it out of the queue; expanding the file changes the item (a new
 * version), which presents the real language and highlights it then.
 * Cached per item object, so CodeView sees a stable item while it is
 * unchanged.
 */
export function presentedItem(item: DiffItem): DiffItem {
  const diff = item.fileDiff;
  if (!item.collapsed || diff == null || diff.lang === "text") {
    return item;
  }
  let presented = plainTextItems.get(item);
  if (presented == null) {
    presented = { ...item, fileDiff: { ...diff, lang: "text", cacheKey: `${diff.cacheKey ?? item.id}:collapsed` } };
    plainTextItems.set(item, presented);
  }
  return presented;
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

const FILE_TREE_ITEM_HEIGHT = 29;
const FILE_TREE_FONT_FAMILY =
  'system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif';

function getInitialFileTreeRowCount(): number {
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
