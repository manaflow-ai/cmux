import type { DiffViewerConfig } from "./types";
import { appearanceBackgroundColor, applyDiffViewerAppearance, resolveDiffViewerAppearance } from "./appearance";
import { planPierreFileTreeRefresh } from "./file-tree-refresh";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";

type GitStatusPatchEntry = {
  path: string;
  status: string;
};

type GitStatusPatch = {
  remove?: string[];
  set?: GitStatusPatchEntry[];
};

type DiffStats = {
  addedLines: number;
  deletedLines: number;
  fileCount: number;
  totalLinesOfCode: number;
};

type FileStats = {
  added: number;
  deleted: number;
};

type DiffItem = {
  collapsed?: boolean;
  fileDiff?: unknown;
  id: string;
  type?: string;
  version?: number;
};

type TreeEntry = {
  item: DiffItem;
  path: string;
  stats: FileStats;
  status: string;
};

type FileTreeSource = {
  diffStats?: DiffStats;
  entries?: TreeEntry[];
  gitStatus?: GitStatusPatchEntry[];
  gitStatusPatch?: GitStatusPatch;
  pathCount?: number;
  paths?: string[];
  pathToItemId?: Map<string, string>;
  previousSource?: FileTreeSource;
  statsChanged?: boolean;
  statsByPath?: Map<string, FileStats>;
  treePathByItemId?: Map<string, string>;
};

type PathState = {
  currentItem: DiffItem;
  currentItemId: string;
  currentType?: string;
  fileOrder: number;
  sawDeleted: boolean;
};

type StreamingDiffModel = {
  diffStats: DiffStats;
  fileIndex: number;
  gitStatusByPath: Map<string, GitStatusPatchEntry>;
  itemIdByTreePath: Map<string, string>;
  itemIdToFile: Map<string, { fileOrder: number; path: string }>;
  items: DiffItem[];
  lastTreeSource?: FileTreeSource;
  nextCollisionSuffixByBase: Map<string, number>;
  paths: string[];
  pathStateByTreePath: Map<string, PathState>;
  pathToItemId: Map<string, string>;
  pendingGitStatusRemovePaths: Set<string>;
  pendingGitStatusSetByPath: Map<string, GitStatusPatchEntry>;
  pendingItemById: Map<string, DiffItem>;
  pendingItems: DiffItem[];
  pendingStatsChanged: boolean;
  statsByPath: Map<string, FileStats>;
  treePathByItemId: Map<string, string>;
};

type RenameDiffItem = {
  newId: string;
  oldId: string;
};

type ShortcutStroke = {
  command: boolean;
  control: boolean;
  key: string;
  option: boolean;
  shift: boolean;
};

type ShortcutBinding = {
  first: ShortcutStroke;
  second: ShortcutStroke | null;
};

type PendingChord = {
  action: () => void;
  shortcut: ShortcutBinding;
};

type PatchTextPromiseState = {
  value: Promise<string> | null;
};

type OptionsMenuActionItem = {
  action?: () => void;
  checked?: boolean;
  disabled?: boolean;
  icon: string;
  kind?: "action";
  label: string;
};

type OptionsMenuSegmentItem = {
  icon: string;
  kind: "segment";
  label: string;
  options: Array<{
    icon: string;
    label: string;
    value: string;
  }>;
};

type OptionsMenuItem = "separator" | OptionsMenuActionItem | OptionsMenuSegmentItem;

type StatusMessageOptions = {
  error?: boolean;
  loading?: boolean;
  pending?: boolean;
  statusOnly?: boolean;
};

export function startDiffViewer(config: DiffViewerConfig): void {
  const requireElement = <T extends HTMLElement>(id: string): T => {
    const element = document.getElementById(id);
    if (!element) {
      throw new Error(`Missing cmux diff viewer element: ${id}`);
    }
    return element as T;
  };
  const assets = config.assets ?? {};
  const resolveAssetURL = (value: string | undefined, name: string): string => {
    if (typeof value !== "string" || value.length === 0) {
      throw new Error(`Missing cmux diff viewer asset: ${name}`);
    }
    return new URL(value, window.location.href).href;
  };
  const DIFFS_MODULE_URL = resolveAssetURL(assets.diffsModuleURL, "diffsModuleURL");
  const TREES_MODULE_URL = resolveAssetURL(assets.treesModuleURL, "treesModuleURL");
  const WORKER_POOL_MODULE_URL = resolveAssetURL(assets.workerPoolModuleURL, "workerPoolModuleURL");
  const DIFF_WORKER_URL = resolveAssetURL(assets.workerModuleURL, "workerModuleURL");
  const payload = config.payload ?? {};
const appearance = resolveDiffViewerAppearance(payload.appearance);
const viewerElement = requireElement<HTMLElement>("viewer");
const status = requireElement<HTMLDivElement>("status");
const statusText = requireElement<HTMLSpanElement>("status-text");
const toolbar = requireElement<HTMLElement>("toolbar");
const sourceSelect = requireElement<HTMLSelectElement>("source-select");
const repoSelect = requireElement<HTMLSelectElement>("repo-select");
const baseSelect = requireElement<HTMLSelectElement>("base-select");
const sourceDetail = requireElement<HTMLElement>("source-detail");
const jumpSelect = requireElement<HTMLSelectElement>("jump-select");
const externalLink = requireElement<HTMLAnchorElement>("external-link");
const filesToggle = requireElement<HTMLButtonElement>("files-toggle");
const layoutToggle = requireElement<HTMLButtonElement>("layout-toggle");
const optionsButton = requireElement<HTMLButtonElement>("options-button");
const optionsMenu = requireElement<HTMLElement>("options-menu");
const filesSidebar = requireElement<HTMLElement>("files-sidebar");
const fileList = requireElement<HTMLElement>("file-list");
const filesCount = requireElement<HTMLElement>("files-count");
const fileSearchToggle = requireElement<HTMLButtonElement>("file-search-toggle");
const fileCollapseToggle = requireElement<HTMLButtonElement>("file-collapse-toggle");
const statsFiles = requireElement<HTMLElement>("stats-files");
const statsAdded = requireElement<HTMLElement>("stats-added");
const statsDeleted = requireElement<HTMLElement>("stats-deleted");
const label = createDiffViewerLabelResolver(payload.labels, {
  assertMissing: shouldAssertMissingLabels(),
});
const appState = {
  layout: payload.layout === "unified" ? "unified" : "split",
  filesVisible: true,
  wordWrap: false,
  collapsed: false,
  expandUnchanged: false,
  showBackgrounds: true,
  lineNumbers: true,
  diffIndicators: "bars",
  wordDiffs: false,
  fileSearchOpen: false,
};
let codeView;
let workerPool;
let fileTree;
const diffItems: DiffItem[] = [];
const codeViewItems: DiffItem[] = [];
const diffItemById = new Map<string, DiffItem>();
let codeViewItemIds = new Set<string>();
let fileTreeSource: FileTreeSource | null = null;
let currentTreeSource: FileTreeSource | null = null;
let fileTreeStatsByPath = new Map<string, FileStats>();
let patchTextPromise: PatchTextPromiseState = { value: null };
let activeFileId = "";
let activeTreePath = "";
let suppressTreeSelectionChange = false;
let itemIdByTreePath = new Map();
let treePathByItemId = new Map();
if (typeof payload.title === "string" && payload.title.trim() !== "") {
  document.title = payload.title;
}
applyDiffViewerAppearance(appearance);
setupToolbar();
setupSourceSelector(payload.sourceOptions ?? []);
setupNavigationSelector(repoSelect, payload.repoOptions ?? [], payload.repoRoot ?? "", label("repoPath"));
setupNavigationSelector(baseSelect, payload.baseOptions ?? [], payload.branchBaseRef ?? "", label("branchBase"));
const scheduleRender = globalThis.queueMicrotask ?? ((callback) => setTimeout(callback, 0));
if (payload.pendingReplacement === true) {
  showStatusMessage(payload.statusMessage ?? label("loadingDiff"), { loading: true, pending: true });
  waitForReplacement();
} else if (typeof payload.statusMessage === "string" && payload.statusMessage.length > 0) {
  showStatusMessage(payload.statusMessage, { error: payload.statusIsError === true, loading: false, statusOnly: true });
} else {
  scheduleRender(() => {
    renderDiff().catch((error) => {
      console.error("cmux diff viewer render failed", error);
      showStatusMessage(label("renderFailed"), { error: true, loading: false, statusOnly: true });
    });
  });
}

async function renderDiff() {
  showStatusMessage(label("loadingRenderer"), { loading: true });
  const [
    {
      CodeView,
      getFiletypeFromFileName,
      parsePatchFiles,
      preloadHighlighter,
      processFile,
      registerCustomTheme,
    },
    treesModule,
  ] = await Promise.all([
    // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
    import(DIFFS_MODULE_URL),
    // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
    import(TREES_MODULE_URL).catch((error) => {
      console.warn("cmux diff file tree import failed", error);
      return null;
    }),
  ]);

  registerGhosttyTheme(registerCustomTheme, appearance.themes.light);
  registerGhosttyTheme(registerCustomTheme, appearance.themes.dark);
  showStatusMessage(label("parsingDiff"), { loading: true });
  setWorkerPoolStatus("loading");
  workerPool = await createCodeViewWorkerPool();
  setupJumpSelector(diffItems);
  updateToolbarState();
  window.__cmuxDiffViewer = { codeView, items: diffItems, state: appState, workerPool };
  observeWorkerPool(workerPool);
  const workerInitialization = workerPool?.initialize?.();
  workerInitialization
    ?.then?.(() => recordWorkerPoolStats(workerPool?.getStats?.()))
    ?.catch?.((error) => console.warn("cmux diff worker pool initialization failed", error));
  window.addEventListener("pagehide", () => workerPool?.terminate?.(), { once: true });

  // oxlint-disable-next-line react-doctor/async-defer-await -- diffItems is populated by the awaited stream before the guard below can run.
  await streamPatchIntoCodeView({
    CodeView,
    parsePatchFiles,
    processFile,
    treesModule,
  });

  if (diffItems.length === 0) {
    throw new Error(label("noFileDiffs"));
  }

  if (!workerPool) {
    preloadDiffHighlighter(appearance, codeViewItems.length > 0 ? codeViewItems : diffItems, getFiletypeFromFileName, preloadHighlighter)
      .catch((error) => console.warn("cmux diff highlighter preload failed", error));
  }
}

function showStatusMessage(message: string, options: StatusMessageOptions = {}): void {
  if (!status.isConnected) {
    viewerElement.replaceChildren(status);
  }
  document.body.dataset.loading = options.loading === true || options.pending === true ? "true" : "false";
  document.body.dataset.statusOnly = options.statusOnly === true ? "true" : "false";
  status.dataset.error = options.error === true ? "true" : "false";
  status.dataset.pending = options.pending === true ? "true" : "false";
  // Write into the dedicated text node so the empty-state icon child survives.
  statusText.textContent = message;
}

async function applyReplacementFrom(response: Response): Promise<boolean> {
  if (!response.ok) {
    showStatusMessage(label("renderFailed"), { error: true, loading: false, statusOnly: true });
    return false;
  }
  const text = await response.text();
  if (text.includes("data-cmux-diff-pending=\"true\"")) {
    return false;
  }
  // The deferred page already evaluated main.mjs, and module scripts run once
  // per realm, so document.write-ing the replacement HTML would leave an empty
  // #root. Reload instead: a fresh document load re-bootstraps React against
  // the now-final on-disk HTML the server serves.
  window.location.reload();
  return true;
}

async function waitForReplacement() {
  try {
    const response = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
    await applyReplacementFrom(response);
  } catch (error) {
    document.documentElement.dataset.cmuxDiffWait = "failed";
    showStatusMessage(label("renderFailed"), { error: true, loading: false, statusOnly: true });
    console.warn("cmux diff viewer deferred load failed", error);
  }
}

async function createCodeViewWorkerPool() {
  if (typeof Worker === "undefined") {
    return null;
  }
  try {
    // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
    const workerPoolModule = await import(WORKER_POOL_MODULE_URL);
    registerGhosttyTheme(workerPoolModule.registerCustomTheme, appearance.themes.light);
    registerGhosttyTheme(workerPoolModule.registerCustomTheme, appearance.themes.dark);
    const workerURL = new URL(DIFF_WORKER_URL, window.location.href).href;
    return workerPoolModule.createDiffWorkerPool({
      workerURL,
      highlighterOptions: workerHighlighterOptions(),
    }) ?? null;
  } catch (error) {
    console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", error);
    return null;
  }
}

function observeWorkerPool(pool) {
  if (!pool) {
    setWorkerPoolStatus("fallback");
    return;
  }
  setWorkerPoolStatus("enabled");
  recordWorkerPoolStats(pool.getStats?.());
  const unsubscribe = pool.subscribeToStatChanges?.((stats) => {
    recordWorkerPoolStats(stats);
  });
  if (typeof unsubscribe === "function") {
    window.addEventListener("pagehide", unsubscribe, { once: true });
  }
}

function setWorkerPoolStatus(status) {
  document.body.dataset.workerPool = status;
}

function recordWorkerPoolStats(stats) {
  if (!stats || typeof stats !== "object") {
    return;
  }
  if (typeof stats.managerState === "string") {
    document.body.dataset.workerPoolState = stats.managerState;
  }
  if (Number.isFinite(stats.totalWorkers)) {
    document.body.dataset.workerPoolWorkers = String(stats.totalWorkers);
  }
  if (typeof stats.workersFailed === "boolean") {
    document.body.dataset.workerPoolFailed = String(stats.workersFailed);
  }
}

function workerHighlighterOptions() {
  return {
    theme: appearance.theme,
    preferredHighlighter: "shiki-wasm",
    lineDiffType: appState.wordDiffs ? "word" : "none",
    maxLineDiffLength: 1000,
    tokenizeMaxLineLength: 1000,
    useTokenTransformer: false,
  };
}

const commitMetadataPattern = /^From\s+([a-f0-9]+)\s/im;

function commitMetadataLabel(metadata, index) {
  const match = metadata?.match(commitMetadataPattern);
  if (match?.[1]) {
    return new TextDecoder().decode(new TextEncoder().encode(match[1].slice(0, 5)));
  }
  return `${label("commit")} ${index + 1}`;
}

async function streamPatchIntoCodeView({ CodeView, parsePatchFiles, processFile, treesModule }) {
  const diffModel = createStreamingDiffModel();
  const navigationRefreshState = {
    dirtyCount: 0,
    lastRefreshAt: 0,
    timeout: 0,
    treesModule: null,
  };
  const streamMetrics: {
    completedAt: number;
    fileCount?: number;
    flushCount: number;
    maxBatchSize: number;
    renderableFileCount?: number;
    startedAt: number;
    treeRefreshCount: number;
  } = {
    startedAt: performance.now(),
    completedAt: 0,
    flushCount: 0,
    maxBatchSize: 0,
    treeRefreshCount: 0,
  };
  let lastYieldAt = performance.now();
  let lastFlushAt = performance.now();
  let firstRender = true;
  const batchConfig = {
    initialBatchSize: getInitialFileTreeRowCount(),
    incrementalBatchSize: 25,
    initialMaxWait: 500,
    incrementalMaxWait: 100,
  };

  function makeItem(fileDiff, patchPrefix) {
    const result = appendFileDiffToModel(diffModel, fileDiff, patchPrefix);
    if (result?.renamedItem) {
      applyRenamedDiffItem(result.renamedItem);
    }
    return result?.item;
  }

  function appendFileDiffToModel(model, fileDiff, patchPrefix) {
    if (!fileDiff) {
      return null;
    }
    const path = fileName(fileDiff);
    const treePath = patchPrefix == null ? path : `${patchPrefix}/${path}`;
    const previousState = path.length === 0 ? undefined : model.pathStateByTreePath.get(treePath);
    const renamedItem = previousState == null ? undefined : moveCurrentPathItemToPrevious(model, treePath, previousState);
    const stats = fileStats(fileDiff);
    const itemId = model.itemIdToFile.has(treePath) ? uniqueDiffItemId(model, `${treePath}?2`) : treePath;
    const item = {
      id: itemId,
      type: "diff",
      fileDiff,
      version: 0,
      // Inherit the current collapse state so items flushed after "Collapse all
      // diffs" (while a large diff is still streaming) render collapsed too.
      collapsed: appState.collapsed,
    };
    const fileOrder = model.items.length;
    model.fileIndex += 1;
    model.items.push(item);
    model.pendingItems.push(item);
    model.pendingItemById.set(item.id, item);
    model.itemIdToFile.set(item.id, { fileOrder, path });
    model.itemIdByTreePath.set(treePath, item.id);
    model.treePathByItemId.set(item.id, treePath);
    model.diffStats.addedLines += stats.added;
    model.diffStats.deletedLines += stats.deleted;
    model.diffStats.fileCount += 1;
    model.diffStats.totalLinesOfCode += fileDiff.unifiedLineCount ?? fileDiff.splitLineCount ?? 0;
    const previousStats = model.statsByPath.get(treePath);
    model.statsByPath.set(treePath, stats);
    if (previousState != null && !sameFileStats(previousStats, stats)) {
      model.pendingStatsChanged = true;
    }
    if (path.length > 0) {
      if (previousState == null) {
        model.paths.push(treePath);
      }
      model.pathToItemId.set(treePath, item.id);
      updateGitStatusForPath(model, treePath, fileDiff.type, previousState?.sawDeleted === true);
      model.pathStateByTreePath.set(treePath, {
        currentItem: item,
        currentItemId: item.id,
        currentType: fileDiff.type,
        fileOrder,
        sawDeleted: previousState?.sawDeleted === true || fileDiff.type === "deleted",
      });
    }
    return { item, renamedItem };
  }

  function moveCurrentPathItemToPrevious(model, treePath, state) {
    const oldId = state.currentItemId;
    const suffix = state.currentType === "deleted" ? "?deleted" : "?previous";
    const newId = uniqueDiffItemId(model, `${treePath}${suffix}`);
    state.currentItem.id = newId;
    state.currentItemId = newId;
    if (model.itemIdToFile.has(oldId)) {
      const itemMetadata = model.itemIdToFile.get(oldId);
      model.itemIdToFile.delete(oldId);
      model.itemIdToFile.set(newId, itemMetadata);
    }
    if (model.treePathByItemId.has(oldId)) {
      model.treePathByItemId.delete(oldId);
      model.treePathByItemId.set(newId, treePath);
    }
    if (model.pendingItemById.has(oldId)) {
      const pendingItem = model.pendingItemById.get(oldId);
      model.pendingItemById.delete(oldId);
      model.pendingItemById.set(newId, pendingItem);
      return undefined;
    }
    return { oldId, newId };
  }

  function uniqueDiffItemId(model, baseId) {
    if (!model.itemIdToFile.has(baseId)) {
      return baseId;
    }
    let suffix = model.nextCollisionSuffixByBase.get(baseId) ?? 2;
    let nextId = `${baseId}-${suffix}`;
    while (model.itemIdToFile.has(nextId)) {
      suffix += 1;
      nextId = `${baseId}-${suffix}`;
    }
    model.nextCollisionSuffixByBase.set(baseId, suffix + 1);
    return nextId;
  }

  function updateGitStatusForPath(model, treePath, changeType, sawDeleted) {
    if (sawDeleted && changeType !== "deleted") {
      if (model.gitStatusByPath.delete(treePath)) {
        markGitStatusRemoved(model, treePath);
      }
      return;
    }
    const status = gitStatusType(changeType);
    if (status === "modified") {
      if (model.gitStatusByPath.delete(treePath)) {
        markGitStatusRemoved(model, treePath);
      }
      return;
    }
    const current = model.gitStatusByPath.get(treePath);
    if (current?.status === status) {
      return;
    }
    const entry = { path: treePath, status };
    model.gitStatusByPath.set(treePath, entry);
    model.pendingGitStatusRemovePaths.delete(treePath);
    model.pendingGitStatusSetByPath.set(treePath, entry);
  }

  function markGitStatusRemoved(model, treePath) {
    model.pendingGitStatusSetByPath.delete(treePath);
    model.pendingGitStatusRemovePaths.add(treePath);
  }

  function applyRenamedDiffItem(rename: RenameDiffItem) {
    if (codeViewItemIds.delete(rename.oldId)) {
      codeViewItemIds.add(rename.newId);
    }
    if (diffItemById.has(rename.oldId)) {
      const item = diffItemById.get(rename.oldId);
      diffItemById.delete(rename.oldId);
      if (item) {
        diffItemById.set(rename.newId, item);
      }
    }
    renameJumpOption(rename.oldId, rename.newId);
    codeView?.updateItemId?.(rename.oldId, rename.newId);
  }

  async function enqueueFileDiff(fileDiff, patchPrefix) {
    const item = makeItem(fileDiff, patchPrefix);
    if (!item) {
      return;
    }
    await maybeFlushPendingItems(false);
  }

  async function maybeFlushPendingItems(force) {
    if (diffModel.pendingItems.length === 0) {
      return;
    }
    const now = performance.now();
    if (!force &&
        firstRender &&
        now - lastYieldAt >= 8 &&
        diffModel.pendingItems.length < batchConfig.initialBatchSize &&
        now - lastFlushAt < batchConfig.initialMaxWait) {
      await yieldToNextFrame();
      lastYieldAt = performance.now();
      return;
    }
    const batchSize = firstRender ? batchConfig.initialBatchSize : batchConfig.incrementalBatchSize;
    const maxWait = firstRender ? batchConfig.initialMaxWait : batchConfig.incrementalMaxWait;
    const shouldFlush = force ||
      diffModel.pendingItems.length >= batchSize ||
      now - lastFlushAt >= maxWait;
    if (shouldFlush) {
      flushPendingItems();
      await yieldToNextFrame();
      lastYieldAt = performance.now();
      return;
    }
  }

  function flushPendingItems() {
    if (diffModel.pendingItems.length === 0) {
      return;
    }
    const batch = diffModel.pendingItems.splice(0, diffModel.pendingItems.length);
    diffModel.pendingItemById.clear();
    const codeBatch = batch;
    const hadCodeItems = codeViewItems.length > 0;
    diffItems.push(...batch);
    for (const item of batch) {
      diffItemById.set(item.id, item);
    }
    if (codeBatch.length > 0) {
      codeViewItems.push(...codeBatch);
      for (const item of codeBatch) {
        codeViewItemIds.add(item.id);
      }
      if (!codeView) {
        codeView = new CodeView(codeViewOptions(), workerPool ?? undefined);
        codeView.setup(viewerElement);
        codeView.setItems(codeViewItems);
        codeView.render(true);
        if (window.__cmuxDiffViewer) {
          window.__cmuxDiffViewer.codeView = codeView;
        }
      } else {
        codeView.addItems(codeBatch);
      }
    }
    appendJumpOptions(batch);
    scheduleNavigationRefresh(treesModule, false, batch.length);
    streamMetrics.flushCount += 1;
    streamMetrics.maxBatchSize = Math.max(streamMetrics.maxBatchSize, batch.length);
    streamMetrics.fileCount = diffItems.length;
    streamMetrics.renderableFileCount = codeViewItems.length;
    recordStreamMetrics(streamMetrics);
    lastFlushAt = performance.now();
    if (firstRender) {
      firstRender = false;
      document.body.dataset.loading = "false";
      status.remove();
    }
    if (!hadCodeItems) {
      updateActiveFile(codeViewItems[0]?.id ?? diffItems[0]?.id ?? "");
    }
    if (window.__cmuxDiffViewer) {
      window.__cmuxDiffViewer.items = diffItems;
      window.__cmuxDiffViewer.codeViewItems = codeViewItems;
      window.__cmuxDiffViewer.streamMetrics = streamMetrics;
    }
  }

  function finalizeCodeViewLayout() {
    if (!codeView) {
      return;
    }
    codeView.syncContainerHeight?.();
    codeView.render(true);
  }

  function scheduleNavigationRefresh(treesModule, force, dirtyCount = 1) {
    navigationRefreshState.treesModule = treesModule;
    navigationRefreshState.dirtyCount += dirtyCount;
    if (force || navigationRefreshState.lastRefreshAt === 0) {
      refreshNavigation(navigationRefreshState.treesModule);
      return;
    }
    const elapsed = performance.now() - navigationRefreshState.lastRefreshAt;
    if (navigationRefreshState.dirtyCount >= 1000 || elapsed >= 1000) {
      refreshNavigation(navigationRefreshState.treesModule);
      return;
    }
    if (navigationRefreshState.timeout !== 0) {
      return;
    }
    const delay = Math.max(0, 1000 - elapsed);
    navigationRefreshState.timeout = window.setTimeout(() => {
      navigationRefreshState.timeout = 0;
      refreshNavigation(navigationRefreshState.treesModule);
    }, delay);
  }

  function refreshNavigation(treesModule) {
    if (navigationRefreshState.timeout !== 0) {
      window.clearTimeout(navigationRefreshState.timeout);
      navigationRefreshState.timeout = 0;
    }
    navigationRefreshState.dirtyCount = 0;
    navigationRefreshState.lastRefreshAt = performance.now();
    streamMetrics.treeRefreshCount += 1;
    currentTreeSource = createFileTreeSourceFromModel(diffModel);
    refreshFileExplorerSource(currentTreeSource, treesModule);
    updateToolbarState();
    recordStreamMetrics(streamMetrics);
  }

  const response = await fetch(payload.patchURL, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`${label("loadingDiff")} (${response.status})`);
  }

  if (!response.body?.getReader) {
    // oxlint-disable-next-line react-doctor/async-parallel -- parsing depends on the fetched text, and flushing depends on parsed items.
    const text = await response.text();
    await appendParsedPatchText(text, parsePatchFiles, enqueueFileDiff);
    await maybeFlushPendingItems(true);
    finalizeCodeViewLayout();
    scheduleNavigationRefresh(treesModule, true);
    streamMetrics.completedAt = performance.now();
    return;
  }

  const decoder = new TextDecoder();
  const reader = response.body.getReader();
  const gitMarker = "diff --git ";
  const gitMarkerWithNewline = "\n" + gitMarker;
  const gitMarkerSearchTailLength = gitMarkerWithNewline.length - 1;
  const nonWhitespacePattern = /\S/;

  function nextGitBoundaryIndex(text, start) {
    const offset = Math.max(start, 0);
    if (offset === 0 && text.startsWith(gitMarker)) {
      return 0;
    }
    const index = text.indexOf(gitMarkerWithNewline, offset);
    return index === -1 ? undefined : index + 1;
  }

  function nextGitBoundarySearchStart(text, start) {
    return Math.max(start, text.length - gitMarkerSearchTailLength);
  }

  function commitMetadataBoundaryIndex(text, start, end) {
    const minimum = Math.max(start, 0);
    const maximum = Math.min(end, text.length);
    if (minimum >= maximum) {
      return undefined;
    }
    let index = text.lastIndexOf("\nFrom ", maximum - 1);
    while (index !== -1) {
      const boundary = index + 1;
      if (boundary < minimum) {
        return undefined;
      }
      if (boundary >= maximum) {
        index = text.lastIndexOf("\nFrom ", index - 1);
        continue;
      }
      const lineEnd = text.indexOf("\n", boundary + 1);
      const line = text.slice(boundary, lineEnd === -1 || lineEnd > maximum ? maximum : lineEnd);
      if (commitMetadataPattern.test(line)) {
        return boundary;
      }
      index = text.lastIndexOf("\nFrom ", index - 1);
    }
    return undefined;
  }

  function commitMetadataFromFileText(fileText) {
    const firstGitBoundary = nextGitBoundaryIndex(fileText, 0);
    if (firstGitBoundary == null || firstGitBoundary <= 0) {
      return undefined;
    }
    const metadata = fileText.slice(0, firstGitBoundary);
    return commitMetadataPattern.test(metadata) ? metadata : undefined;
  }

  async function appendCompleteFileText(fileText) {
    if (fileText.trim() === "") {
      return;
    }
    const metadata = commitMetadataFromFileText(fileText);
    if (metadata != null) {
      currentPatchPrefix = commitMetadataLabel(metadata, patchMetadataIndex);
      patchMetadataIndex += 1;
    }
    const cacheKey = `cmux-diff-file-${diffModel.fileIndex}`;
    await enqueueFileDiff(processFile(fileText, {
      cacheKey,
      isGitDiff: true,
    }), currentPatchPrefix);
  }

  function createStreamingPatchFileSplitter() {
    let boundaryIndex;
    let buffer = "";
    let searchStart = 0;
    let sawGitBoundary = false;

    function takeAvailableFile() {
      if (boundaryIndex == null) {
        boundaryIndex = nextGitBoundaryIndex(buffer, searchStart);
        if (boundaryIndex == null) {
          searchStart = nextGitBoundarySearchStart(buffer, 0);
          return null;
        }
        sawGitBoundary = true;
        searchStart = boundaryIndex + 1;
      }

      while (true) {
        const currentBoundary = boundaryIndex;
        if (currentBoundary == null) {
          return null;
        }
        const nextBoundary = nextGitBoundaryIndex(buffer, searchStart);
        if (nextBoundary == null) {
          searchStart = nextGitBoundarySearchStart(buffer, currentBoundary + 1);
          return null;
        }
        const splitBoundary = commitMetadataBoundaryIndex(buffer, currentBoundary + 1, nextBoundary) ?? nextBoundary;
        const fileText = buffer.slice(0, splitBoundary);
        buffer = buffer.slice(splitBoundary);
        boundaryIndex = nextGitBoundaryIndex(buffer, 0);
        searchStart = boundaryIndex == null ? 0 : boundaryIndex + 1;
        if (nonWhitespacePattern.test(fileText)) {
          return fileText;
        }
      }
    }

    return {
      push(text) {
        if (text.length > 0) {
          buffer += text;
        }
      },
      takeAvailableFile,
      finish() {
        const fileText = takeAvailableFile();
        if (fileText != null) {
          return { fileText };
        }
        if (!nonWhitespacePattern.test(buffer)) {
          buffer = "";
          return {};
        }
        if (!sawGitBoundary) {
          const fallbackPatchContent = buffer;
          buffer = "";
          return { fallbackPatchContent };
        }
        const trailingFileText = buffer;
        buffer = "";
        return { fileText: trailingFileText };
      },
    };
  }

  async function drainPatchFileSplitter(splitter) {
    let fileText;
    while ((fileText = splitter.takeAvailableFile()) != null) {
      // oxlint-disable-next-line react-doctor/async-await-in-loop -- diff files must be appended in patch order for stable navigation and batching.
      await appendCompleteFileText(fileText);
    }
  }

  const splitter = createStreamingPatchFileSplitter();
  let currentPatchPrefix;
  let patchMetadataIndex = 0;
  while (true) {
    // oxlint-disable-next-line react-doctor/async-await-in-loop -- ReadableStream readers are inherently sequential.
    const { done, value } = await reader.read();
    if (done) {
      const tail = decoder.decode();
      if (tail.length > 0) {
        splitter.push(tail);
        await drainPatchFileSplitter(splitter);
      }
      break;
    }
    splitter.push(decoder.decode(value, { stream: true }));
    await drainPatchFileSplitter(splitter);
  }

  const finalFile = splitter.finish();
  if (finalFile.fileText != null) {
    await appendCompleteFileText(finalFile.fileText);
    await drainPatchFileSplitter(splitter);
  } else if (finalFile.fallbackPatchContent != null) {
    await appendParsedPatchText(finalFile.fallbackPatchContent, parsePatchFiles, enqueueFileDiff);
  }
  await maybeFlushPendingItems(true);
  finalizeCodeViewLayout();
  scheduleNavigationRefresh(treesModule, true);
  streamMetrics.completedAt = performance.now();
  recordStreamMetrics(streamMetrics);
}

function recordStreamMetrics(metrics) {
  document.body.dataset.streamFileCount = String(metrics.fileCount ?? diffItems.length);
  document.body.dataset.streamRenderableFileCount = String(metrics.renderableFileCount ?? codeViewItems.length);
  document.body.dataset.streamFlushCount = String(metrics.flushCount ?? 0);
  document.body.dataset.streamMaxBatchSize = String(metrics.maxBatchSize ?? 0);
  document.body.dataset.streamTreeRefreshCount = String(metrics.treeRefreshCount ?? 0);
  if (Number.isFinite(metrics.completedAt) && metrics.completedAt > 0) {
    document.body.dataset.streamElapsedMs = String(Math.round(metrics.completedAt - metrics.startedAt));
  }
}

async function appendParsedPatchText(patchText, parsePatchFiles, enqueueFileDiff) {
  const patches = parsePatchFiles(patchText, "cmux-diff");
  const hasMultiplePatches = patches.length > 1;
  for (const [patchIndex, patch] of patches.entries()) {
    const patchPrefix = hasMultiplePatches ? commitMetadataLabel(patch.patchMetadata, patchIndex) : undefined;
    for (const fileDiff of patch.files ?? []) {
      // oxlint-disable-next-line react-doctor/async-await-in-loop -- diff files must be enqueued in patch order for stable navigation and batching.
      await enqueueFileDiff(fileDiff, patchPrefix);
    }
  }
}

function createStreamingDiffModel(): StreamingDiffModel {
  return {
    diffStats: {
      addedLines: 0,
      deletedLines: 0,
      fileCount: 0,
      totalLinesOfCode: 0,
    },
    fileIndex: 0,
    gitStatusByPath: new Map(),
    itemIdToFile: new Map(),
    itemIdByTreePath: new Map(),
    lastTreeSource: undefined,
    nextCollisionSuffixByBase: new Map(),
    items: [],
    pathStateByTreePath: new Map(),
    paths: [],
    pathToItemId: new Map(),
    pendingGitStatusRemovePaths: new Set(),
    pendingGitStatusSetByPath: new Map(),
    pendingItems: [],
    pendingItemById: new Map(),
    pendingStatsChanged: false,
    statsByPath: new Map(),
    treePathByItemId: new Map(),
  };
}

function createFileTreeSourceFromModel(model: StreamingDiffModel): FileTreeSource {
  const previousSource = model.lastTreeSource;
  const gitStatusPatch = buildGitStatusPatch(model);
  const source = {
    diffStats: { ...model.diffStats },
    gitStatus: Array.from(model.gitStatusByPath.values()),
    gitStatusPatch,
    pathCount: model.paths.length,
    paths: model.paths,
    pathToItemId: model.pathToItemId,
    previousSource,
    statsChanged: model.pendingStatsChanged,
    statsByPath: model.statsByPath,
    treePathByItemId: model.treePathByItemId,
  };
  model.pendingStatsChanged = false;
  model.lastTreeSource = source;
  return source;
}

function buildGitStatusPatch(model: StreamingDiffModel): GitStatusPatch | undefined {
  if (model.pendingGitStatusRemovePaths.size === 0 && model.pendingGitStatusSetByPath.size === 0) {
    return undefined;
  }
  const patch: GitStatusPatch = {};
  if (model.pendingGitStatusRemovePaths.size > 0) {
    patch.remove = Array.from(model.pendingGitStatusRemovePaths);
    model.pendingGitStatusRemovePaths.clear();
  }
  if (model.pendingGitStatusSetByPath.size > 0) {
    patch.set = Array.from(model.pendingGitStatusSetByPath.values());
    model.pendingGitStatusSetByPath.clear();
  }
  return patch;
}

function yieldToNextFrame() {
  return new Promise<void>((resolve) => {
    let resolved = false;
    let timeout = 0;
    const done = () => {
      if (resolved) {
        return;
      }
      resolved = true;
      if (timeout !== 0) {
        window.clearTimeout(timeout);
      }
      resolve();
    };
    if (document.visibilityState === "visible" && document.hasFocus()) {
      timeout = window.setTimeout(done, 50);
      window.requestAnimationFrame(done);
    } else if (typeof MessageChannel !== "undefined") {
      const channel = new MessageChannel();
      channel.port1.onmessage = done;
      channel.port2.postMessage(undefined);
    } else {
      queueMicrotask(done);
    }
  });
}

async function loadPatchText() {
  if (patchTextPromise.value == null) {
    patchTextPromise.value = fetch(payload.patchURL, { cache: "no-store" }).then(async (response) => {
      if (!response.ok) {
        throw new Error(`${label("loadingDiff")} (${response.status})`);
      }
      return response.text();
    });
  }
  return patchTextPromise.value;
}

function setupToolbar() {
  filesToggle.innerHTML = icon("files");
  fileSearchToggle.innerHTML = icon("search");
  fileCollapseToggle.innerHTML = icon("sidebarCollapse");
  layoutToggle.innerHTML = icon(appState.layout);
  optionsButton.innerHTML = icon("dots");
  if (typeof payload.externalURL === "string" && payload.externalURL.length > 0) {
    externalLink.href = payload.externalURL;
    externalLink.innerHTML = icon("external");
    externalLink.hidden = false;
  }
  filesToggle.addEventListener("click", () => setFilesVisible(!appState.filesVisible));
  fileCollapseToggle.addEventListener("click", () => setFilesVisible(false));
  fileSearchToggle.addEventListener("click", () => setFileSearchOpen(!appState.fileSearchOpen));
  layoutToggle.addEventListener("click", () => setLayout(appState.layout === "split" ? "unified" : "split"));
  optionsButton.addEventListener("click", () => setOptionsMenuOpen(optionsMenu.hidden));
  document.addEventListener("click", (event) => {
    if (optionsMenu.hidden || (event.target instanceof Node && toolbar.contains(event.target))) {
      return;
    }
    setOptionsMenuOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      setOptionsMenuOpen(false);
    }
  });
  setupKeyboardShortcuts();
  updateToolbarState();
}

function setupKeyboardShortcuts() {
  const shortcuts = payload.shortcuts ?? {};
  const scrollDownShortcut = normalizeShortcut(shortcuts.diffViewerScrollDown);
  const scrollUpShortcut = normalizeShortcut(shortcuts.diffViewerScrollUp);
  const scrollBottomShortcut = normalizeShortcut(shortcuts.diffViewerScrollToBottom);
  const scrollTopShortcut = normalizeShortcut(shortcuts.diffViewerScrollToTop);
  const fileSearchShortcut = normalizeShortcut(shortcuts.diffViewerOpenFileSearch);
  let pendingChord: PendingChord | null = null;
  let chordTimeout = 0;
  document.addEventListener("keydown", (event) => {
    if (event.defaultPrevented || isTypingShortcutTarget(event.target)) {
      return;
    }
    if (pendingChord && !shortcutStrokeMatchesEvent(pendingChord.shortcut.second, event)) {
      clearPendingChord();
    }
    if (pendingChord && shortcutStrokeMatchesEvent(pendingChord.shortcut.second, event)) {
      event.preventDefault();
      pendingChord.action();
      clearPendingChord();
      return;
    }
    if (shortcutMatchesEvent(scrollDownShortcut, event)) {
      event.preventDefault();
      scrollViewerBy(1);
      return;
    }
    if (shortcutMatchesEvent(scrollUpShortcut, event)) {
      event.preventDefault();
      scrollViewerBy(-1);
      return;
    }
    if (shortcutMatchesEvent(scrollBottomShortcut, event)) {
      event.preventDefault();
      viewerElement.scrollTo({ top: viewerElement.scrollHeight, behavior: "auto" });
      return;
    }
    if (shortcutMatchesEvent(fileSearchShortcut, event) && fileTree) {
      event.preventDefault();
      setFilesVisible(true);
      setFileSearchOpen(true);
      return;
    }
    if (scrollTopShortcut && shortcutStartsChord(scrollTopShortcut, event)) {
      event.preventDefault();
      pendingChord = {
        shortcut: scrollTopShortcut,
        action: () => viewerElement.scrollTo({ top: 0, behavior: "auto" }),
      };
      chordTimeout = window.setTimeout(clearPendingChord, 700);
    }
  });

  function clearPendingChord() {
    pendingChord = null;
    if (chordTimeout !== 0) {
      window.clearTimeout(chordTimeout);
      chordTimeout = 0;
    }
  }
}

function normalizeShortcut(rawShortcut) {
  if (!rawShortcut || rawShortcut.unbound === true || !rawShortcut.first) {
    return null;
  }
  return {
    first: normalizeShortcutStroke(rawShortcut.first),
    second: rawShortcut.second ? normalizeShortcutStroke(rawShortcut.second) : null,
  };
}

function normalizeShortcutStroke(rawStroke) {
  return {
    key: String(rawStroke?.key ?? "").toLowerCase(),
    command: rawStroke?.command === true,
    shift: rawStroke?.shift === true,
    option: rawStroke?.option === true,
    control: rawStroke?.control === true,
  };
}

function shortcutMatchesEvent(shortcut, event) {
  return shortcut && !shortcut.second && shortcutStrokeMatchesEvent(shortcut.first, event);
}

function shortcutStartsChord(shortcut, event) {
  return shortcut && shortcut.second && shortcutStrokeMatchesEvent(shortcut.first, event);
}

function shortcutStrokeMatchesEvent(stroke, event) {
  if (!stroke || event.metaKey !== stroke.command || event.ctrlKey !== stroke.control || event.altKey !== stroke.option) {
    return false;
  }
  if (event.shiftKey !== stroke.shift) {
    return false;
  }
  const eventKey = normalizedShortcutEventKey(event);
  return eventKey === stroke.key;
}

function normalizedShortcutEventKey(event) {
  if (event.code === "Space") {
    return "space";
  }
  if (typeof event.key !== "string" || event.key.length === 0) {
    return "";
  }
  if (event.key.length === 1) {
    return event.key.toLowerCase();
  }
  return event.key.toLowerCase();
}

function isTypingShortcutTarget(target) {
  const element = target instanceof Element ? target : null;
  if (!element) {
    return false;
  }
  if (element.closest("input, textarea, select, [contenteditable='true']")) {
    return true;
  }
  return false;
}

function scrollViewerBy(direction) {
  const amount = Math.max(80, Math.floor(viewerElement.clientHeight * 0.38));
  viewerElement.scrollBy({ top: direction * amount, behavior: "auto" });
}

function codeViewOptions() {
  return {
    layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
    diffStyle: appState.layout,
    diffIndicators: appState.diffIndicators,
    overflow: appState.wordWrap ? "wrap" : "scroll",
    expandUnchanged: appState.expandUnchanged,
    disableBackground: !appState.showBackgrounds,
    disableLineNumbers: !appState.lineNumbers,
    lineHoverHighlight: "number",
    enableLineSelection: true,
    enableGutterUtility: true,
    lineDiffType: appState.wordDiffs ? "word" : "none",
    stickyHeaders: true,
    unsafeCSS: codeViewUnsafeCSS(),
    theme: appearance.theme,
    themeType: "system",
  };
}

function codeViewUnsafeCSS() {
  return `
    [data-diffs-header] {
      container-type: scroll-state;
      container-name: sticky-header;
    }
    @container sticky-header scroll-state(stuck: top) {
      [data-diffs-header]::after {
        position: absolute;
        bottom: -1px;
        left: 0;
        width: 100%;
        height: 1px;
        content: '';
        background-color: var(--cmux-diff-border);
      }
    }
    [data-diffs-header=default],
    [data-diffs-header=default] [data-additions-count],
    [data-diffs-header=default] [data-deletions-count],
    [data-separator-wrapper],
    [data-separator-content],
    [data-unmodified-lines],
    [data-expand-button] {
      font-family: var(--diffs-header-font-family, var(--diffs-header-font-fallback));
    }
  `;
}

function applyCodeViewOptions() {
  const options = codeViewOptions();
  if (!codeView) {
    syncWorkerRenderOptions();
    return;
  }
  codeView.setOptions(options);
  syncWorkerRenderOptions();
  codeView.render(true);
}

function syncWorkerRenderOptions() {
  if (!workerPool?.setRenderOptions) {
    return;
  }
  workerPool.setRenderOptions(workerHighlighterOptions())
    .then(() => codeView?.render(true))
    .catch((error) => console.warn("cmux diff worker render options update failed", error));
}

function setLayout(layout) {
  appState.layout = layout === "unified" ? "unified" : "split";
  updateToolbarState();
  applyCodeViewOptions();
}

function setFilesVisible(visible) {
  appState.filesVisible = visible;
  document.body.dataset.filesHidden = visible ? "false" : "true";
  filesSidebar.setAttribute("aria-hidden", String(!visible));
  if (visible) {
    filesSidebar.removeAttribute("inert");
  } else {
    filesSidebar.setAttribute("inert", "");
  }
  updateToolbarState();
}

function setFileSearchOpen(open) {
  appState.fileSearchOpen = Boolean(open);
  if (fileTree) {
    if (appState.fileSearchOpen) {
      fileTree.openSearch("");
    } else {
      fileTree.closeSearch();
    }
  }
  updateToolbarState();
}

function setCollapsed(collapsed) {
  appState.collapsed = collapsed;
  const nextCodeViewItems = codeViewItems.map((item) => ({
    ...item,
    collapsed,
    version: (item.version ?? 0) + 1,
  }));
  const codeItemsById = new Map(nextCodeViewItems.map((item) => [item.id, item]));
  const nextDiffItems = diffItems.map((item) => codeItemsById.get(item.id) ?? {
    ...item,
    collapsed,
    version: (item.version ?? 0) + 1,
  });
  codeViewItems.splice(0, codeViewItems.length, ...nextCodeViewItems);
  diffItems.splice(0, diffItems.length, ...nextDiffItems);
  if (codeView) {
    codeView.setItems(codeViewItems);
    codeView.render(true);
  }
  updateToolbarState();
}

function updateToolbarState() {
  filesToggle.setAttribute("aria-pressed", String(appState.filesVisible));
  filesToggle.title = appState.filesVisible ? label("hideFiles") : label("showFiles");
  filesToggle.setAttribute("aria-label", filesToggle.title);
  fileCollapseToggle.title = label("hideFiles");
  fileCollapseToggle.setAttribute("aria-label", fileCollapseToggle.title);
  layoutToggle.innerHTML = icon(appState.layout);
  layoutToggle.title = appState.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff");
  layoutToggle.setAttribute("aria-label", layoutToggle.title);
  optionsButton.setAttribute("aria-expanded", String(!optionsMenu.hidden));
  document.documentElement.dataset.layout = appState.layout;
  document.documentElement.dataset.wordWrap = String(appState.wordWrap);
  document.documentElement.dataset.diffIndicators = appState.diffIndicators;
  fileSearchToggle.disabled = !fileTree;
  fileSearchToggle.setAttribute("aria-pressed", String(appState.fileSearchOpen));
  fileSearchToggle.title = appState.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch");
  fileSearchToggle.setAttribute("aria-label", fileSearchToggle.title);
}

function setOptionsMenuOpen(open) {
  if (open) {
    renderOptionsMenu();
  }
  optionsMenu.hidden = !open;
  updateToolbarState();
}

function renderOptionsMenu() {
  optionsMenu.textContent = "";
  const items: OptionsMenuItem[] = [
    { label: label("refresh"), icon: "refresh", action: () => window.location.reload() },
    { label: appState.wordWrap ? label("disableWordWrap") : label("enableWordWrap"), icon: "wrap", checked: appState.wordWrap, action: () => {
      appState.wordWrap = !appState.wordWrap;
      applyCodeViewOptions();
    } },
    { label: appState.collapsed ? label("expandAllDiffs") : label("collapseAllDiffs"), icon: "collapse", checked: appState.collapsed, action: () => setCollapsed(!appState.collapsed) },
    "separator",
    { label: appState.filesVisible ? label("hideFiles") : label("showFiles"), icon: "files", checked: appState.filesVisible, action: () => setFilesVisible(!appState.filesVisible) },
    { label: appState.expandUnchanged ? label("collapseUnchangedContext") : label("expandUnchangedContext"), icon: "document", checked: appState.expandUnchanged, action: () => {
      appState.expandUnchanged = !appState.expandUnchanged;
      applyCodeViewOptions();
    } },
    { label: appState.showBackgrounds ? label("hideBackgrounds") : label("showBackgrounds"), icon: "background", checked: appState.showBackgrounds, action: () => {
      appState.showBackgrounds = !appState.showBackgrounds;
      applyCodeViewOptions();
    } },
    { label: appState.lineNumbers ? label("hideLineNumbers") : label("showLineNumbers"), icon: "numbers", checked: appState.lineNumbers, action: () => {
      appState.lineNumbers = !appState.lineNumbers;
      applyCodeViewOptions();
    } },
    { label: appState.wordDiffs ? label("disableWordDiffs") : label("enableWordDiffs"), icon: "word", checked: appState.wordDiffs, action: () => {
      appState.wordDiffs = !appState.wordDiffs;
      applyCodeViewOptions();
    } },
    { kind: "segment", label: label("indicatorStyle"), icon: "bars", options: [
      { value: "bars", icon: "bars", label: label("bars") },
      { value: "classic", icon: "classic", label: label("classic") },
      { value: "none", icon: "eye", label: label("none") },
    ] },
    "separator",
    { label: label("copyGitApplyCommand"), icon: "clipboard", action: copyGitApplyCommand },
  ];
  for (const item of items) {
    if (item === "separator") {
      const separator = document.createElement("div");
      separator.className = "menu-separator";
      optionsMenu.append(separator);
      continue;
    }
    if (item.kind === "segment") {
      const row = document.createElement("div");
      row.className = "menu-item menu-segment";
      row.setAttribute("role", "presentation");
      row.innerHTML = `${icon(item.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
      const labelElement = row.querySelector<HTMLElement>(".menu-label");
      if (labelElement) {
        labelElement.textContent = item.label;
      }
      const controls = row.querySelector<HTMLElement>(".menu-segment-controls");
      if (!controls) {
        continue;
      }
      for (const option of item.options) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "segment-button";
        button.title = option.label;
        button.setAttribute("aria-label", option.label);
        button.setAttribute("aria-pressed", String(appState.diffIndicators === option.value));
        button.innerHTML = icon(option.icon);
        button.addEventListener("click", () => {
          appState.diffIndicators = option.value;
          applyCodeViewOptions();
          renderOptionsMenu();
          updateToolbarState();
        });
        controls.append(button);
      }
      optionsMenu.append(row);
      continue;
    }
    const button = document.createElement("button");
    button.type = "button";
    button.className = "menu-item";
    button.setAttribute("role", item.checked == null ? "menuitem" : "menuitemcheckbox");
    if (item.checked != null) {
      button.setAttribute("aria-checked", String(Boolean(item.checked)));
    }
    button.disabled = Boolean(item.disabled);
    button.innerHTML = `${icon(item.icon)}<span class="menu-label"></span><span class="menu-check">${item.checked ? icon("check") : ""}</span>`;
    const labelElement = button.querySelector<HTMLElement>(".menu-label");
    if (labelElement) {
      labelElement.textContent = item.label;
    }
    button.addEventListener("click", () => {
      if (button.disabled) {
        return;
      }
      item.action?.();
      renderOptionsMenu();
      updateToolbarState();
    });
    optionsMenu.append(button);
  }
}

function safeGitApplyDelimiter(patch) {
  const lines = new Set(patch.split(/\r?\n/));
  let delimiter = "CMUX_DIFF_PATCH";
  let index = 0;
  while (lines.has(delimiter)) {
    index += 1;
    delimiter = `CMUX_DIFF_PATCH_${index}`;
  }
  return delimiter;
}

async function copyGitApplyCommand() {
  const newline = String.fromCharCode(10);
  const patchText = await loadPatchText();
  const patch = patchText.endsWith(newline) ? patchText : `${patchText}${newline}`;
  const delimiter = safeGitApplyDelimiter(patch);
  const command = `git apply <<'${delimiter}'${newline}${patch}${delimiter}`;
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      fallbackCopyText(command);
    }
  } else {
    fallbackCopyText(command);
  }
  optionsButton.title = label("copiedGitApplyCommand");
  optionsButton.setAttribute("aria-label", label("copiedGitApplyCommand"));
}

function fallbackCopyText(text) {
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  document.body.append(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

function setupSourceSelector(options) {
  sourceDetail.textContent = diffSourceDetail();
  if (!Array.isArray(options) || options.length < 2) {
    return;
  }
  sourceSelect.textContent = "";
  const selected = options.find((option) => option.selected) ?? options.find((option) => !option.disabled);
  for (const option of options) {
    const item = document.createElement("option");
    item.value = option.value;
    item.textContent = option.label;
    item.disabled = option.disabled || !option.url;
    item.selected = option.value === selected?.value;
    if (option.message) {
      item.title = option.message;
    }
    sourceSelect.append(item);
  }
  sourceDetail.textContent = selected?.sourceLabel ?? diffSourceDetail();
  sourceSelect.hidden = false;
  sourceSelect.addEventListener("change", () => {
    const next = options.find((option) => option.value === sourceSelect.value);
    if (!next?.url) {
      sourceSelect.value = selected?.value ?? "";
      return;
    }
    showStatusMessage(label("loadingDiff"), { pending: true });
    window.location.href = resolveDiffNavigationURL(next.url);
  });
}

// A restored diff viewer runs under the app-owned cmux-diff-viewer:// scheme,
// but the source/repo/base option URLs were generated against the now-dead
// local HTTP server. Rewrite them to the custom scheme (reusing the current
// page's token as the host, dropping query/fragment the scheme handler rejects)
// so the diff switcher keeps working post-restore. Same-session http pages pass
// through unchanged.
function resolveDiffNavigationURL(rawURL: string): string {
  try {
    const target = new URL(rawURL, window.location.href);
    if (
      window.location.protocol === "cmux-diff-viewer:" &&
      (target.protocol === "http:" || target.protocol === "https:")
    ) {
      const rest = target.pathname.split("/").filter(Boolean).slice(1).join("/");
      return `cmux-diff-viewer://${window.location.host}/${rest}`;
    }
    return target.href;
  } catch {
    return rawURL;
  }
}

function diffSourceDetail() {
  const parts = [payload.sourceLabel, payload.repoRoot, payload.branchBaseRef]
    .filter((value) => typeof value === "string" && value.trim() !== "");
  return parts.join(" | ");
}

function setupNavigationSelector(selectElement, options, fallbackValue, labelText) {
  if (!selectElement || !Array.isArray(options) || options.length < 2) {
    return;
  }
  selectElement.textContent = "";
  const selected = options.find((option) => option.selected) ?? options.find((option) => !option.disabled);
  for (const option of options) {
    const item = document.createElement("option");
    item.value = option.value;
    item.textContent = option.label;
    item.disabled = option.disabled || !option.url;
    item.selected = option.value === selected?.value;
    if (option.message) {
      item.title = option.message;
    }
    selectElement.append(item);
  }
  selectElement.hidden = false;
  selectElement.title = labelText;
  selectElement.addEventListener("change", () => {
    const next = options.find((option) => option.value === selectElement.value);
    if (!next?.url) {
      selectElement.value = selected?.value ?? fallbackValue ?? "";
      return;
    }
    showStatusMessage(label("loadingDiff"), { pending: true });
    window.location.href = resolveDiffNavigationURL(next.url);
  });
}

function setupFileExplorerSource(source, treesModule) {
  const itemCount = sourcePathCount(source);
  const canUsePierreTree = canUsePierreFileTree(treesModule);
  syncFileTreeSelectionMaps(source, []);
  if (fileTree) {
    fileTree.cleanUp?.();
    fileTree = null;
  }
  fileTreeSource = null;
  appState.fileSearchOpen = false;
  fileList.textContent = "";
  filesCount.textContent = `${itemCount}`;
  updateDiffStatsFromSource(source);
  if (canUsePierreTree) {
    try {
      setupPierreFileTree(source, treesModule);
      updateToolbarState();
      return;
    } catch (error) {
      console.warn("cmux diff file tree setup failed", error);
    }
  }
  const entries = sourceEntries(source);
  syncFileTreeSelectionMaps(source, entries);
  setupFlatFileExplorer(entries);
  updateToolbarState();
}

function refreshFileExplorerSource(source, treesModule) {
  const itemCount = sourcePathCount(source);
  syncFileTreeSelectionMaps(source, []);
  filesCount.textContent = `${itemCount}`;
  updateDiffStatsFromSource(source);
  if (fileTree && fileList.dataset.treeMode === "pierre" && treesModule?.preparePresortedFileTreeInput) {
    refreshPierreFileTree(source, treesModule);
    return;
  }
  if (fileTree || fileList.childElementCount === 0) {
    setupFileExplorerSource(source, treesModule);
    return;
  }
  const entries = sourceEntries(source);
  syncFileTreeSelectionMaps(source, entries);
  fileList.textContent = "";
  setupFlatFileExplorer(entries);
}

function setupPierreFileTree(source, treesModule) {
  const { FileTree, preparePresortedFileTreeInput } = treesModule;
  const paths = sourcePaths(source);
  fileTreeSource = source;
  const initialSelectedPath = paths[0];
  updateFileTreeStatsFromSource(source);
  fileList.dataset.treeMode = "pierre";
  fileTree = new FileTree({
    flattenEmptyDirectories: true,
    id: "cmux-diff-file-tree",
    initialExpansion: "open",
    initialSelectedPaths: initialSelectedPath ? [initialSelectedPath] : [],
    initialVisibleRowCount: getInitialFileTreeRowCount(),
    itemHeight: 24,
    overscan: 12,
    preparedInput: preparePresortedFileTreeInput(paths),
    search: true,
    searchBlurBehavior: "retain",
    stickyFolders: true,
    gitStatus: source.gitStatus,
    renderRowDecoration(context) {
      if (context.item.kind !== "file") {
        return null;
      }
      const stats = fileTreeStatsByPath.get(context.item.path);
      if (stats == null || (stats.added === 0 && stats.deleted === 0)) {
        return null;
      }
      return {
        text: `+${stats.added} -${stats.deleted}`,
        title: `${stats.added} ${label("additions")}, ${stats.deleted} ${label("deletions")}`,
      };
    },
    sort: () => 0,
    unsafeCSS: fileTreeUnsafeCSS(),
    onSelectionChange(paths) {
      if (suppressTreeSelectionChange) {
        return;
      }
      const selectedPath = paths[paths.length - 1];
      const itemId = itemIdByTreePath.get(selectedPath);
      if (itemId) {
        scrollToItem(itemId);
      }
    },
  });
  fileTree.render({ containerWrapper: fileList });
}

function refreshPierreFileTree(source, treesModule) {
  const previousSource = fileTreeSource;
  const paths = sourcePaths(source);
  fileTreeSource = source;
  updateFileTreeStatsFromSource(source);
  let resetTree = false;
  const plan = planPierreFileTreeRefresh(previousSource, source, paths);
  if (plan.kind === "append") {
    const addedPaths = plan.addedPaths;
    if (addedPaths.length > 0) {
      try {
        fileTree.batch(addedPaths.map((path) => ({ type: "add", path })));
      } catch (error) {
        console.warn("cmux diff file tree incremental update failed; resetting paths", error);
        fileTree.resetPaths(paths, {
          preparedInput: treesModule.preparePresortedFileTreeInput(paths),
        });
        resetTree = true;
      }
    }
  } else {
    fileTree.resetPaths(paths, {
      preparedInput: treesModule.preparePresortedFileTreeInput(paths),
    });
    resetTree = true;
  }
  if (source.gitStatusPatch) {
    if (typeof fileTree.applyGitStatusPatch === "function") {
      fileTree.applyGitStatusPatch(source.gitStatusPatch);
    } else {
      fileTree.setGitStatus(source.gitStatus);
    }
  } else if (resetTree || source.statsChanged === true) {
    fileTree.setGitStatus(source.gitStatus);
  }
}

function canUsePierreFileTree(treesModule) {
  return Boolean(treesModule?.FileTree && treesModule?.preparePresortedFileTreeInput);
}

function sourcePathCount(source) {
  return source?.pathCount ?? source?.entries?.length ?? 0;
}

function sourceEntries(source) {
  const count = source?.pathCount ?? source?.entries?.length ?? 0;
  const entries = source?.entries ?? [];
  if (entries.length > 0) {
    return entries.length === count ? entries : entries.slice(0, count);
  }
  const paths = sourcePaths(source);
  const pathToItemId = source?.pathToItemId;
  const statsByPath = source?.statsByPath;
  return paths.map((path) => {
    const itemId = pathToItemId instanceof Map ? pathToItemId.get(path) : undefined;
    const item = itemId ? diffItemById.get(itemId) : undefined;
    const fileDiff = item?.fileDiff ?? {};
    return {
      item: item ?? { id: itemId ?? path, fileDiff },
      path,
      status: gitStatus(fileDiff),
      stats: statsByPath instanceof Map ? statsByPath.get(path) ?? fileStats(fileDiff) : fileStats(fileDiff),
    };
  });
}

function sourcePaths(source) {
  const count = source?.pathCount ?? source?.paths?.length ?? 0;
  const paths = source?.paths ?? [];
  return paths.length === count ? paths : paths.slice(0, count);
}

function updateFileTreeStatsFromSource(source) {
  if (source?.statsByPath instanceof Map) {
    fileTreeStatsByPath = source.statsByPath;
    return;
  }
  fileTreeStatsByPath = new Map();
  const treeEntries = sourceEntries(source);
  for (const entry of treeEntries) {
    fileTreeStatsByPath.set(entry.path, entry.stats);
  }
}

function syncFileTreeSelectionMaps(source, entries) {
  if (source?.pathToItemId instanceof Map && source?.treePathByItemId instanceof Map) {
    itemIdByTreePath = source.pathToItemId;
    treePathByItemId = source.treePathByItemId;
  } else if (source?.pathToItemId instanceof Map) {
    itemIdByTreePath = source.pathToItemId;
    treePathByItemId = new Map();
    for (const [path, itemId] of itemIdByTreePath) {
      treePathByItemId.set(itemId, path);
    }
  } else {
    itemIdByTreePath = new Map();
    treePathByItemId = new Map();
    for (const entry of entries) {
      const itemId = entry.item?.id;
      if (!itemId) {
        continue;
      }
      itemIdByTreePath.set(entry.path, itemId);
      treePathByItemId.set(itemId, entry.path);
    }
  }
  if (activeTreePath && !itemIdByTreePath.has(activeTreePath)) {
    activeTreePath = "";
  }
}

function setupFlatFileExplorer(entries) {
  delete fileList.dataset.treeMode;
  for (const entry of entries) {
    const item = entry.item;
    const fileDiff = item.fileDiff ?? {};
    const stats = entry.stats ?? fileStats(fileDiff);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "file-entry";
    button.dataset.itemId = item.id;
    button.title = fileName(fileDiff);
    button.innerHTML = `
      <span class="file-status">${fileStatus(fileDiff)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${stats.added}</span>
        <span class="stat-del">-${stats.deleted}</span>
      </span>
    `;
    const fileNameElement = button.querySelector<HTMLElement>(".file-name");
    if (fileNameElement) {
      fileNameElement.textContent = fileName(fileDiff);
    }
    button.addEventListener("click", () => scrollToItem(item.id));
    fileList.append(button);
  }
}

function getInitialFileTreeRowCount() {
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return 25;
  }
  return Math.min(96, Math.max(25, Math.ceil(viewportHeight / 24)));
}

function fileTreeUnsafeCSS() {
  return `
    [data-file-tree-search-container][data-open='false'] {
      display: none;
    }
    [data-file-tree-search-container] {
      margin: 0 4px 8px 0;
      padding: 0 5px 8px 1px;
      border-bottom: 1px solid var(--trees-border-color);
    }
    [data-file-tree-virtualized-scroll='true'] {
      padding-inline-start: 0;
      padding-inline-end: 2px;
      margin-inline-end: 2px;
    }
    [data-item-contains-git-change='true'] > [data-item-section='git'] {
      display: none;
    }
    [data-item-type='folder'] {
      color: color-mix(in lab, var(--trees-fg) 85%, var(--trees-bg));
      font-weight: 500;
    }
    [data-file-tree-sticky-overlay-content] {
      box-shadow: 0 1px 0 var(--trees-border-color);
    }
  `;
}

function updateDiffStatsFromSource(source) {
  const stats = source?.diffStats;
  if (stats && Number.isFinite(stats.addedLines) && Number.isFinite(stats.deletedLines) && Number.isFinite(stats.fileCount)) {
    statsFiles.textContent = `${stats.fileCount}`;
    statsAdded.textContent = `+${stats.addedLines}`;
    statsDeleted.textContent = `-${stats.deletedLines}`;
    return;
  }
  updateDiffStatsFromEntries(source?.entries ?? []);
}

function updateDiffStatsFromEntries(entries) {
  const totals = entries.reduce((sum, entry) => {
    const stats = entry.stats ?? fileStats(entry.item?.fileDiff ?? {});
    sum.added += stats.added;
    sum.deleted += stats.deleted;
    return sum;
  }, { added: 0, deleted: 0 });
  statsFiles.textContent = `${entries.length}`;
  statsAdded.textContent = `+${totals.added}`;
  statsDeleted.textContent = `-${totals.deleted}`;
}

function setupJumpSelector(items) {
  jumpSelect.textContent = "";
  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.textContent = label("jumpToFile");
  jumpSelect.append(placeholder);
  jumpSelect.dataset.initialized = "true";
  for (const item of items) {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = fileName(item.fileDiff ?? {});
    jumpSelect.append(option);
  }
  jumpSelect.hidden = items.length === 0;
  jumpSelect.onchange = () => {
    if (jumpSelect.value) {
      scrollToItem(jumpSelect.value);
    }
  };
}

function appendJumpOptions(items) {
  if (items.length === 0) {
    return;
  }
  if (jumpSelect.dataset.initialized !== "true") {
    setupJumpSelector([]);
  }
  const fragment = document.createDocumentFragment();
  for (const item of items) {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = fileName(item.fileDiff ?? {});
    fragment.append(option);
  }
  jumpSelect.append(fragment);
  jumpSelect.hidden = false;
}

function renameJumpOption(oldId, newId) {
  if (jumpSelect.dataset.initialized !== "true") {
    return;
  }
  for (const option of jumpSelect.options) {
    if (option.value === oldId) {
      option.value = newId;
      return;
    }
  }
}

function scrollToItem(itemId) {
  if (!codeView) {
    return;
  }
  const targetItemId = codeViewScrollTargetForItem(itemId);
  if (!targetItemId) {
    return;
  }
  codeView.scrollTo({ type: "item", id: targetItemId, align: "start", behavior: "smooth-auto" });
  updateActiveFile(targetItemId);
}

function codeViewScrollTargetForItem(itemId) {
  if (codeViewItemIds.has(itemId)) {
    return itemId;
  }
  const index = diffItems.findIndex((item) => item.id === itemId);
  if (index === -1) {
    return codeViewItems[0]?.id ?? "";
  }
  for (let next = index + 1; next < diffItems.length; next += 1) {
    if (codeViewItemIds.has(diffItems[next].id)) {
      return diffItems[next].id;
    }
  }
  for (let previous = index - 1; previous >= 0; previous -= 1) {
    if (codeViewItemIds.has(diffItems[previous].id)) {
      return diffItems[previous].id;
    }
  }
  return "";
}

function updateActiveFile(itemId) {
  if (!itemId || activeFileId === itemId) {
    return;
  }
  activeFileId = itemId;
  syncFileTreeSelection(itemId);
  for (const entry of fileList.querySelectorAll<HTMLElement>(".file-entry")) {
    entry.setAttribute("aria-current", entry.dataset.itemId === itemId ? "true" : "false");
  }
  if (jumpSelect.value !== itemId) {
    jumpSelect.value = itemId;
  }
}

function syncFileTreeSelection(itemId) {
  if (!fileTree) {
    return;
  }
  const nextPath = treePathByItemId.get(itemId);
  if (!nextPath || nextPath === activeTreePath) {
    return;
  }
  suppressTreeSelectionChange = true;
  try {
    if (activeTreePath) {
      fileTree.getItem(activeTreePath)?.deselect();
    }
    fileTree.getItem(nextPath)?.select();
    fileTree.scrollToPath(nextPath, { focus: false, offset: "nearest" });
    activeTreePath = nextPath;
  } finally {
    scheduleRender(() => {
      suppressTreeSelectionChange = false;
    });
  }
}

function fileName(fileDiff) {
  return fileDiff.name ?? fileDiff.newName ?? fileDiff.oldName ?? fileDiff.prevName ?? label("untitled");
}

function fileStatus(fileDiff) {
  switch (fileDiff.type) {
  case "new":
    return "A";
  case "deleted":
    return "D";
  case "rename-pure":
  case "rename-changed":
    return "R";
  default:
    return "M";
  }
}

function gitStatus(fileDiff) {
  return gitStatusType(fileDiff.type);
}

function gitStatusType(changeType) {
  switch (changeType) {
  case "new":
    return "added";
  case "deleted":
    return "deleted";
  case "rename-pure":
  case "rename-changed":
    return "renamed";
  default:
    return "modified";
  }
}

function fileStats(fileDiff) {
  const stats = { added: 0, deleted: 0 };
  for (const hunk of fileDiff.hunks ?? []) {
    stats.added += hunk.additionLines ?? 0;
    stats.deleted += hunk.deletionLines ?? 0;
  }
  return stats;
}

function sameFileStats(previousStats, stats) {
  return previousStats?.added === stats.added && previousStats?.deleted === stats.deleted;
}

function icon(name) {
  const paths = {
    background: '<rect x="4" y="4" width="12" height="12" rx="2"/><path d="M7 8h6"/><path d="M7 12h6"/>',
    bars: '<path d="M5 4v12"/><path d="M9 6v8"/><path d="M13 8v4"/>',
    check: '<path d="M4 10.5 8 14l8-9"/>',
    classic: '<path d="M4 5h12"/><path d="M4 10h12"/><path d="M4 15h12"/><path d="M7 3v4"/><path d="M13 8v4"/>',
    collapse: '<path d="M7 3v4H3"/><path d="M3 7l5-5"/><path d="M13 17v-4h4"/><path d="M17 13l-5 5"/>',
    document: '<path d="M6 3h6l4 4v10H6z"/><path d="M12 3v5h5"/>',
    dots: '<path d="M5 10h.01"/><path d="M10 10h.01"/><path d="M15 10h.01"/>',
    external: '<path d="M7 5H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-2"/><path d="M11 3h6v6"/><path d="m10 10 7-7"/>',
    eye: '<path d="M2.5 10s2.75-5 7.5-5 7.5 5 7.5 5-2.75 5-7.5 5-7.5-5-7.5-5z"/><circle cx="10" cy="10" r="2.4"/>',
    files: '<path d="M3 5h5l1.5 2H17v9.5H3z"/><path d="M3 7h14"/>',
    image: '<rect x="3" y="4" width="14" height="12" rx="2"/><circle cx="8" cy="8" r="1.3"/><path d="m4 15 4.5-4 3 2.8 2-1.8L17 15"/>',
    numbers: '<path d="M5 5h2v10"/><path d="M4 15h4"/><path d="M11 6.5a2 2 0 1 1 3.2 1.6L11 12h4"/><path d="M11 15h4"/>',
    refresh: '<path d="M16 8a6 6 0 0 0-10.3-3.7L4 6"/><path d="M4 3v3h3"/><path d="M4 12a6 6 0 0 0 10.3 3.7L16 14"/><path d="M16 17v-3h-3"/>',
    search: '<circle cx="8.5" cy="8.5" r="4.5"/><path d="m12 12 4 4"/>',
    sidebarCollapse: '<rect x="3.5" y="4" width="13" height="12" rx="2"/><path d="M12 4v12"/><path d="m8 8-2 2 2 2"/>',
    split: '<rect x="3" y="4" width="14" height="12" rx="2"/><path d="M10 4v12" data-accent="true"/><path d="M6 8h2"/><path d="M6 12h2"/><path d="M12 8h2"/><path d="M12 12h2"/>',
    unified: '<rect x="4" y="3.5" width="12" height="13" rx="2"/><path d="M7 7h6"/><path d="M7 10h6" data-accent="true"/><path d="M7 13h6"/>',
    word: '<path d="M3 6h14"/><path d="M3 10h8"/><path d="M3 14h11"/><path d="M14 10h3"/>',
    wrap: '<path d="M3 6h10a4 4 0 0 1 0 8H8"/><path d="m10 11-3 3 3 3"/>',
    clipboard: '<rect x="5" y="4" width="10" height="13" rx="2"/><path d="M8 4a2 2 0 0 1 4 0"/><path d="M8 7h4"/>',
  };
  return `<svg viewBox="0 0 20 20" aria-hidden="true">${paths[name] ?? ""}</svg>`;
}

function registerGhosttyTheme(registerCustomTheme, theme) {
  registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme)));
}

function preloadDiffHighlighter(appearance, items, getFiletypeFromFileName, preloadHighlighter) {
  const themes = Array.from(new Set([
    appearance.theme?.light,
    appearance.theme?.dark,
  ].filter(Boolean)));
  const langs = Array.from(new Set(items.flatMap((item) => {
    const fileDiff = item.fileDiff ?? {};
    const name = fileDiff.name ?? fileDiff.newName ?? fileDiff.oldName ?? fileDiff.prevName ?? "";
    const lang = fileDiff.lang ?? getFiletypeFromFileName(name) ?? "text";
    return lang ? [lang] : [];
  })));
  return preloadHighlighter({
    themes,
    langs: langs.length > 0 ? langs : ["text"],
  });
}

function shikiThemeFromGhostty(theme) {
  const palette = theme.palette ?? {};
  const foreground = theme.foreground;
  const background = appearanceBackgroundColor(theme.background, appearance);
  return {
    name: theme.name,
    displayName: theme.ghosttyName,
    type: theme.type,
    colors: {
      "editor.background": background,
      "editor.foreground": foreground,
      "terminal.background": background,
      "terminal.foreground": foreground,
      "terminal.ansiBlack": palette["0"] ?? foreground,
      "terminal.ansiRed": palette["1"] ?? foreground,
      "terminal.ansiGreen": palette["2"] ?? foreground,
      "terminal.ansiYellow": palette["3"] ?? foreground,
      "terminal.ansiBlue": palette["4"] ?? foreground,
      "terminal.ansiMagenta": palette["5"] ?? foreground,
      "terminal.ansiCyan": palette["6"] ?? foreground,
      "terminal.ansiWhite": palette["7"] ?? foreground,
      "terminal.ansiBrightBlack": palette["8"] ?? foreground,
      "terminal.ansiBrightRed": palette["9"] ?? palette["1"] ?? foreground,
      "terminal.ansiBrightGreen": palette["10"] ?? palette["2"] ?? foreground,
      "terminal.ansiBrightYellow": palette["11"] ?? palette["3"] ?? foreground,
      "terminal.ansiBrightBlue": palette["12"] ?? palette["4"] ?? foreground,
      "terminal.ansiBrightMagenta": palette["13"] ?? palette["5"] ?? foreground,
      "terminal.ansiBrightCyan": palette["14"] ?? palette["6"] ?? foreground,
      "terminal.ansiBrightWhite": palette["15"] ?? foreground,
      "gitDecoration.addedResourceForeground": palette["10"] ?? palette["2"] ?? "#32d74b",
      "gitDecoration.deletedResourceForeground": palette["9"] ?? palette["1"] ?? "#ff453a",
      "gitDecoration.modifiedResourceForeground": palette["12"] ?? palette["4"] ?? "#0a84ff",
      "editor.selectionBackground": theme.selectionBackground,
      "editor.selectionForeground": theme.selectionForeground,
    },
    tokenColors: [
      { settings: { foreground, background } },
      { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: palette["8"] ?? foreground, fontStyle: "italic" } },
      { scope: ["string", "constant.other.symbol"], settings: { foreground: palette["2"] ?? foreground } },
      { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: palette["3"] ?? foreground } },
      { scope: ["keyword", "storage", "storage.type"], settings: { foreground: palette["5"] ?? foreground } },
      { scope: ["entity.name.function", "support.function"], settings: { foreground: palette["4"] ?? foreground } },
      { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: palette["6"] ?? foreground } },
      { scope: ["variable", "meta.definition.variable"], settings: { foreground } },
      { scope: ["invalid", "message.error"], settings: { foreground: palette["9"] ?? palette["1"] ?? foreground } },
    ],
  };
}

}
