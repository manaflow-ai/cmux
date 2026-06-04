import type { CodeViewItem } from "@pierre/diffs";
import type { DiffViewerLabelResolver } from "./labels";
import type { FileTreeRefreshSource } from "./file-tree-refresh";

export type GitStatusPatchEntry = {
  path: string;
  status: string;
};

export type GitStatusPatch = {
  remove?: string[];
  set?: GitStatusPatchEntry[];
};

export type DiffStats = {
  addedLines: number;
  deletedLines: number;
  fileCount: number;
  totalLinesOfCode: number;
};

export type FileStats = {
  added: number;
  deleted: number;
};

export type DiffItem = CodeViewItem & {
  collapsed?: boolean;
  fileDiff?: any;
  id: string;
  type?: string;
  version?: number;
};

export type FileTreeSource = FileTreeRefreshSource & {
  diffStats: DiffStats;
  gitStatus: GitStatusPatchEntry[];
  gitStatusPatch?: GitStatusPatch;
  pathCount: number;
  paths: string[];
  pathToItemId: Map<string, string>;
  previousSource?: FileTreeSource;
  statsChanged?: boolean;
  statsByPath: Map<string, FileStats>;
  treePathByItemId: Map<string, string>;
};

export type StreamMetrics = {
  completedAt: number;
  fileCount?: number;
  flushCount: number;
  maxBatchSize: number;
  renderableFileCount?: number;
  startedAt: number;
  treeRefreshCount: number;
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

export type StreamPatchOptions = {
  getCollapsed: () => boolean;
  initialFileTreeRowCount: number;
  label: DiffViewerLabelResolver;
  onBatch: (items: DiffItem[]) => void;
  onComplete: (metrics: StreamMetrics) => void;
  onMetrics: (metrics: StreamMetrics) => void;
  onRename: (rename: RenameDiffItem) => void;
  onTreeSource: (source: FileTreeSource) => void;
  parsePatchFiles: (patchText: string, cacheKey: string) => Array<{ files?: any[]; patchMetadata?: string }>;
  patchURL: string;
  processFile: (patchText: string, options: { cacheKey: string; isGitDiff: boolean }) => any;
};

const commitMetadataPattern = /^From\s+([a-f0-9]+)\s/im;

export async function streamPatch(options: StreamPatchOptions): Promise<void> {
  const model = createStreamingDiffModel();
  const metrics: StreamMetrics = {
    startedAt: performance.now(),
    completedAt: 0,
    flushCount: 0,
    maxBatchSize: 0,
    treeRefreshCount: 0,
  };
  let firstRender = true;
  let lastYieldAt = performance.now();
  let lastFlushAt = performance.now();
  let currentPatchPrefix: string | undefined;
  let patchMetadataIndex = 0;
  const batchConfig = {
    initialBatchSize: options.initialFileTreeRowCount,
    incrementalBatchSize: 25,
    initialMaxWait: 500,
    incrementalMaxWait: 100,
  };

  function makeItem(fileDiff: any, patchPrefix: string | undefined): DiffItem | undefined {
    const result = appendFileDiffToModel(model, fileDiff, patchPrefix, options.getCollapsed(), options.label("untitled"));
    if (result?.renamedItem) {
      options.onRename(result.renamedItem);
    }
    return result?.item;
  }

  async function enqueueFileDiff(fileDiff: any, patchPrefix: string | undefined) {
    const item = makeItem(fileDiff, patchPrefix);
    if (!item) {
      return;
    }
    await maybeFlushPendingItems(false);
  }

  async function maybeFlushPendingItems(force: boolean) {
    if (model.pendingItems.length === 0) {
      return;
    }
    const now = performance.now();
    if (
      !force &&
      firstRender &&
      now - lastYieldAt >= 8 &&
      model.pendingItems.length < batchConfig.initialBatchSize &&
      now - lastFlushAt < batchConfig.initialMaxWait
    ) {
      await yieldToNextFrame();
      lastYieldAt = performance.now();
      return;
    }
    const batchSize = firstRender ? batchConfig.initialBatchSize : batchConfig.incrementalBatchSize;
    const maxWait = firstRender ? batchConfig.initialMaxWait : batchConfig.incrementalMaxWait;
    if (force || model.pendingItems.length >= batchSize || now - lastFlushAt >= maxWait) {
      flushPendingItems();
      await yieldToNextFrame();
      lastYieldAt = performance.now();
    }
  }

  function flushPendingItems() {
    if (model.pendingItems.length === 0) {
      return;
    }
    const batch = model.pendingItems.splice(0, model.pendingItems.length);
    model.pendingItemById.clear();
    model.items.push(...batch);
    options.onBatch(batch);
    metrics.flushCount += 1;
    metrics.maxBatchSize = Math.max(metrics.maxBatchSize, batch.length);
    metrics.fileCount = model.items.length;
    metrics.renderableFileCount = model.items.length;
    refreshTreeSource();
    options.onMetrics({ ...metrics });
    lastFlushAt = performance.now();
    firstRender = false;
  }

  function refreshTreeSource() {
    metrics.treeRefreshCount += 1;
    options.onTreeSource(createFileTreeSourceFromModel(model));
  }

  async function appendCompleteFileText(fileText: string) {
    if (fileText.trim() === "") {
      return;
    }
    const metadata = commitMetadataFromFileText(fileText);
    if (metadata != null) {
      currentPatchPrefix = commitMetadataLabel(metadata, patchMetadataIndex, options.label);
      patchMetadataIndex += 1;
    }
    const cacheKey = `cmux-diff-file-${model.fileIndex}`;
    await enqueueFileDiff(options.processFile(fileText, { cacheKey, isGitDiff: true }), currentPatchPrefix);
  }

  const response = await fetch(options.patchURL, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`${options.label("loadingDiff")} (${response.status})`);
  }

  if (!response.body?.getReader) {
    const text = await response.text();
    await appendParsedPatchText(text, options, enqueueFileDiff);
    await maybeFlushPendingItems(true);
    metrics.completedAt = performance.now();
    options.onComplete({ ...metrics });
    return;
  }

  const decoder = new TextDecoder();
  const reader = response.body.getReader();
  const splitter = createStreamingPatchFileSplitter();
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      const tail = decoder.decode();
      if (tail.length > 0) {
        splitter.push(tail);
        await drainPatchFileSplitter(splitter, appendCompleteFileText);
      }
      break;
    }
    splitter.push(decoder.decode(value, { stream: true }));
    await drainPatchFileSplitter(splitter, appendCompleteFileText);
  }

  const finalFile = splitter.finish();
  if (finalFile.fileText != null) {
    await appendCompleteFileText(finalFile.fileText);
    await drainPatchFileSplitter(splitter, appendCompleteFileText);
  } else if (finalFile.fallbackPatchContent != null) {
    await appendParsedPatchText(finalFile.fallbackPatchContent, options, enqueueFileDiff);
  }
  await maybeFlushPendingItems(true);
  metrics.completedAt = performance.now();
  options.onMetrics({ ...metrics });
  options.onComplete({ ...metrics });
}

function createStreamingDiffModel(): StreamingDiffModel {
  return {
    diffStats: { addedLines: 0, deletedLines: 0, fileCount: 0, totalLinesOfCode: 0 },
    fileIndex: 0,
    gitStatusByPath: new Map(),
    itemIdToFile: new Map(),
    itemIdByTreePath: new Map(),
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

function appendFileDiffToModel(
  model: StreamingDiffModel,
  fileDiff: any,
  patchPrefix: string | undefined,
  collapsed: boolean,
  fallbackFileName: string,
): { item: DiffItem; renamedItem?: RenameDiffItem } | null {
  if (!fileDiff) {
    return null;
  }
  const path = fileName(fileDiff, fallbackFileName);
  const treePath = patchPrefix == null ? path : `${patchPrefix}/${path}`;
  const previousState = path.length === 0 ? undefined : model.pathStateByTreePath.get(treePath);
  const renamedItem = previousState == null ? undefined : moveCurrentPathItemToPrevious(model, treePath, previousState);
  const stats = fileStats(fileDiff);
  const itemId = previousState != null || model.itemIdToFile.has(treePath) ? uniqueDiffItemId(model, `${treePath}?2`) : treePath;
  const item: DiffItem = {
    id: itemId,
    type: "diff",
    fileDiff,
    version: 0,
    collapsed,
  };
  const fileOrder = model.items.length + model.pendingItems.length;
  model.fileIndex += 1;
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

function moveCurrentPathItemToPrevious(model: StreamingDiffModel, treePath: string, state: PathState): RenameDiffItem | undefined {
  const oldId = state.currentItemId;
  const suffix = state.currentType === "deleted" ? "?deleted" : "?previous";
  const newId = uniqueDiffItemId(model, `${treePath}${suffix}`);
  const replacementItem = { ...state.currentItem, id: newId };
  state.currentItem = replacementItem;
  state.currentItemId = newId;
  replaceModelItem(model.items, oldId, replacementItem);
  const itemMetadata = model.itemIdToFile.get(oldId);
  if (itemMetadata) {
    model.itemIdToFile.delete(oldId);
    model.itemIdToFile.set(newId, itemMetadata);
  }
  if (model.treePathByItemId.has(oldId)) {
    model.treePathByItemId.delete(oldId);
    model.treePathByItemId.set(newId, treePath);
  }
  if (model.pendingItemById.has(oldId)) {
    replaceModelItem(model.pendingItems, oldId, replacementItem);
    model.pendingItemById.delete(oldId);
    model.pendingItemById.set(newId, replacementItem);
    return undefined;
  }
  return { oldId, newId };
}

function replaceModelItem(items: DiffItem[], oldId: string, replacementItem: DiffItem): void {
  const index = items.findIndex((item) => item.id === oldId);
  if (index !== -1) {
    items[index] = replacementItem;
  }
}

function uniqueDiffItemId(model: StreamingDiffModel, baseId: string): string {
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

function updateGitStatusForPath(model: StreamingDiffModel, treePath: string, changeType: string | undefined, sawDeleted: boolean): void {
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

function markGitStatusRemoved(model: StreamingDiffModel, treePath: string): void {
  model.pendingGitStatusSetByPath.delete(treePath);
  model.pendingGitStatusRemovePaths.add(treePath);
}

function createFileTreeSourceFromModel(model: StreamingDiffModel): FileTreeSource {
  const previousSource = model.lastTreeSource;
  const paths = [...model.paths];
  const source: FileTreeSource = {
    diffStats: { ...model.diffStats },
    gitStatus: Array.from(model.gitStatusByPath.values()),
    gitStatusPatch: buildGitStatusPatch(model),
    pathCount: paths.length,
    paths,
    pathToItemId: new Map(model.pathToItemId),
    previousSource,
    statsChanged: model.pendingStatsChanged,
    statsByPath: new Map(model.statsByPath),
    treePathByItemId: new Map(model.treePathByItemId),
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

async function appendParsedPatchText(
  patchText: string,
  options: StreamPatchOptions,
  enqueueFileDiff: (fileDiff: any, patchPrefix: string | undefined) => Promise<void>,
): Promise<void> {
  const patches = options.parsePatchFiles(patchText, "cmux-diff");
  const hasMultiplePatches = patches.length > 1;
  for (const [patchIndex, patch] of patches.entries()) {
    const patchPrefix = hasMultiplePatches ? commitMetadataLabel(patch.patchMetadata, patchIndex, options.label) : undefined;
    for (const fileDiff of patch.files ?? []) {
      await enqueueFileDiff(fileDiff, patchPrefix);
    }
  }
}

function createStreamingPatchFileSplitter() {
  let boundaryIndex: number | undefined;
  let buffer = "";
  let searchStart = 0;
  let sawGitBoundary = false;
  const gitMarker = "diff --git ";
  const gitMarkerWithNewline = "\n" + gitMarker;
  const gitMarkerSearchTailLength = gitMarkerWithNewline.length - 1;
  const nonWhitespacePattern = /\S/;

  function nextGitBoundaryIndex(text: string, start: number): number | undefined {
    const offset = Math.max(start, 0);
    if (offset === 0 && text.startsWith(gitMarker)) {
      return 0;
    }
    const index = text.indexOf(gitMarkerWithNewline, offset);
    return index === -1 ? undefined : index + 1;
  }

  function nextGitBoundarySearchStart(text: string, start: number): number {
    return Math.max(start, text.length - gitMarkerSearchTailLength);
  }

  function takeAvailableFile(): string | null {
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
    push(text: string) {
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

async function drainPatchFileSplitter(
  splitter: ReturnType<typeof createStreamingPatchFileSplitter>,
  appendCompleteFileText: (fileText: string) => Promise<void>,
): Promise<void> {
  let fileText: string | null;
  while ((fileText = splitter.takeAvailableFile()) != null) {
    await appendCompleteFileText(fileText);
  }
}

function commitMetadataBoundaryIndex(text: string, start: number, end: number): number | undefined {
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

function commitMetadataFromFileText(fileText: string): string | undefined {
  const firstGitBoundary = nextGitBoundaryIndex(fileText, 0);
  if (firstGitBoundary == null || firstGitBoundary <= 0) {
    return undefined;
  }
  const metadata = fileText.slice(0, firstGitBoundary);
  return commitMetadataPattern.test(metadata) ? metadata : undefined;
}

function nextGitBoundaryIndex(text: string, start: number): number | undefined {
  const gitMarker = "diff --git ";
  const gitMarkerWithNewline = "\n" + gitMarker;
  const offset = Math.max(start, 0);
  if (offset === 0 && text.startsWith(gitMarker)) {
    return 0;
  }
  const index = text.indexOf(gitMarkerWithNewline, offset);
  return index === -1 ? undefined : index + 1;
}

function commitMetadataLabel(metadata: string | undefined, index: number, label: DiffViewerLabelResolver): string {
  const match = metadata?.match(commitMetadataPattern);
  if (match?.[1]) {
    return new TextDecoder().decode(new TextEncoder().encode(match[1].slice(0, 5)));
  }
  return `${label("commit")} ${index + 1}`;
}

export function fileName(fileDiff: any, fallback = "Untitled"): string {
  return fileDiff.name ?? fileDiff.newName ?? fileDiff.oldName ?? fileDiff.prevName ?? fallback;
}

export function fileStats(fileDiff: any): FileStats {
  const stats = { added: 0, deleted: 0 };
  for (const hunk of fileDiff.hunks ?? []) {
    stats.added += hunk.additionLines ?? 0;
    stats.deleted += hunk.deletionLines ?? 0;
  }
  return stats;
}

function sameFileStats(previousStats: FileStats | undefined, stats: FileStats): boolean {
  return previousStats?.added === stats.added && previousStats?.deleted === stats.deleted;
}

function gitStatusType(changeType: string | undefined): string {
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

function yieldToNextFrame(): Promise<void> {
  return new Promise((resolve) => {
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
