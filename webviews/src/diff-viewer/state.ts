// Owns the diff viewer's app state: the state shape, its actions, the initial state and the reducer.
import { applyCommentAnnotations, withCommentAnnotations } from "../comments/annotations";
import type { CommentDraft, DiffCommentRecord } from "../comments/types";
import { deferredDiffReason } from "../deferred-diffs";
import { fileName, fileStats, type DiffItem, type FileTreeSource, type StreamMetrics } from "../diff-stream";
import { collapsedFileKey } from "../collapsed-files";
import { defaultDiffFileFilter, type DiffFileFilter } from "../file-filter";
import { type DiffViewerOptions } from "../pierre-options";
import { createDiffViewerStatus } from "../status";
import {
  type ViewedChange,
  type ViewedFileEntry,
  type ViewedSession,
  applyLoadedViewed,
  beginViewedLoad,
  recordViewedChange,
  viewedScopeKey,
  viewedScopeKeyRepoRoot,
  viewedStateOfItem,
} from "../viewed-files";
import { readLocalViewerPrefs, sanitizeViewerPrefs, type ViewerPrefs } from "../viewer-prefs";
import type { DiffViewerStatus } from "../status";
import type { DiffViewerConfig } from "../types";
import { diffItemPreloadLanguages, mergeLanguages, relanguagedItems, resolveDiffItemLanguage } from "./item-languages";

export type AppState = {
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

export type AppAction =
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

export type DiffViewerLayout = DiffViewerOptions["layout"];

export function initialAppState(config: DiffViewerConfig, initialStatus: DiffViewerStatus): AppState {
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

export function itemCollapsedFileKey(item: DiffItem, scopeKey: string): string {
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

export function reducer(state: AppState, action: AppAction): AppState {
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
