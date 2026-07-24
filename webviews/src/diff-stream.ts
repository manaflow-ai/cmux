import type { CodeViewItem } from "@pierre/diffs";
import type { CommentAnnotationMetadata } from "./comments/types";
import type { DiffViewerLabelResolver } from "./labels";
import type { FileTreeRefreshSource } from "./file-tree-refresh";
import { annotateDiffMetadata } from "./diff-metadata";

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

export type DiffItem = CodeViewItem<CommentAnnotationMetadata> & {
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
  previousRevision?: number;
  revision: number;
  statsChanged?: boolean;
  statsByPath: Map<string, FileStats>;
  treePathByItemId: Map<string, string>;
};

export type StreamMetrics = {
  completedAt: number;
  fileCount?: number;
  firstBatchAt?: number;
  firstBatchFileCount?: number;
  flushCount: number;
  longYieldCount: number;
  maxBatchSize: number;
  maxYieldMs: number;
  renderableFileCount?: number;
  startedAt: number;
  treeRefreshCount: number;
  yieldCount: number;
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
  gitStatusEntries: GitStatusPatchEntry[];
  gitStatusIndexByPath: Map<string, number>;
  itemIdByTreePath: Map<string, string>;
  itemIdToFile: Map<string, { fileOrder: number; path: string }>;
  items: DiffItem[];
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
  treeRevision: number;
};

type RenameDiffItem = {
  newId: string;
  oldId: string;
};

export type StreamPatchOptions = {
  getCollapsed: () => boolean;
  initialFileTreeRowCount: number;
  label: DiffViewerLabelResolver;
  signal?: AbortSignal;
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
  const throwIfAborted = () => {
    if (options.signal?.aborted) {
      throw options.signal.reason ?? new DOMException("The diff stream was cancelled", "AbortError");
    }
  };
  const model = createStreamingDiffModel();
  const metrics: StreamMetrics = {
    startedAt: performance.now(),
    completedAt: 0,
    flushCount: 0,
    longYieldCount: 0,
    maxBatchSize: 0,
    maxYieldMs: 0,
    treeRefreshCount: 0,
    yieldCount: 0,
  };
  let firstRender = true;
  let lastYieldAt = performance.now();
  let lastFlushAt = performance.now();
  let nextIncrementalBatchSize = 128;
  let currentPatchPrefix: string | undefined;
  let patchMetadataIndex = 0;
  const batchConfig = {
    initialBatchSize: options.initialFileTreeRowCount,
    maxIncrementalBatchSize: 4_096,
    initialMaxWait: 500,
    incrementalMaxWait: 100,
  };

  function makeItem(fileDiff: any, patchPrefix: string | undefined): DiffItem | undefined {
    throwIfAborted();
    annotateDiffMetadata(fileDiff);
    normalizeGitFileDiffPaths(fileDiff);
    const result = appendFileDiffToModel(model, fileDiff, patchPrefix, options.getCollapsed(), options.label("untitled"));
    if (result?.renamedItem) {
      options.onRename(result.renamedItem);
    }
    return result?.item;
  }

  async function enqueueFileDiff(fileDiff: any, patchPrefix: string | undefined) {
    throwIfAborted();
    const item = makeItem(fileDiff, patchPrefix);
    if (!item) {
      return;
    }
    await maybeFlushPendingItems(false);
  }

  async function maybeFlushPendingItems(force: boolean) {
    throwIfAborted();
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
      await measuredYield();
      lastYieldAt = performance.now();
      return;
    }
    const batchSize = firstRender ? batchConfig.initialBatchSize : nextIncrementalBatchSize;
    const maxWait = firstRender ? batchConfig.initialMaxWait : batchConfig.incrementalMaxWait;
    if (force || model.pendingItems.length >= batchSize || now - lastFlushAt >= maxWait) {
      flushPendingItems();
      await measuredYield();
      lastYieldAt = performance.now();
    }
  }

  function flushPendingItems() {
    throwIfAborted();
    if (model.pendingItems.length === 0) {
      return;
    }
    const batch = model.pendingItems.splice(0, model.pendingItems.length);
    model.pendingItemById.clear();
    model.items.push(...batch);
    options.onBatch(batch);
    if (metrics.firstBatchAt == null) {
      metrics.firstBatchAt = performance.now();
      metrics.firstBatchFileCount = batch.length;
    }
    metrics.flushCount += 1;
    metrics.maxBatchSize = Math.max(metrics.maxBatchSize, batch.length);
    metrics.fileCount = model.items.length;
    metrics.renderableFileCount = model.items.length;
    refreshTreeSource();
    options.onMetrics({ ...metrics });
    lastFlushAt = performance.now();
    if (!firstRender) {
      nextIncrementalBatchSize = Math.min(nextIncrementalBatchSize * 4, batchConfig.maxIncrementalBatchSize);
    }
    firstRender = false;
  }

  async function measuredYield() {
    throwIfAborted();
    const startedAt = performance.now();
    await yieldToNextFrame();
    const duration = performance.now() - startedAt;
    metrics.yieldCount += 1;
    metrics.maxYieldMs = Math.max(metrics.maxYieldMs, duration);
    if (duration > 16) {
      metrics.longYieldCount += 1;
    }
  }

  function refreshTreeSource() {
    throwIfAborted();
    metrics.treeRefreshCount += 1;
    options.onTreeSource(createFileTreeSourceFromModel(model));
  }

  async function appendCompleteFileText(fileText: string) {
    throwIfAborted();
    if (fileText.trim() === "") {
      return;
    }
    const metadata = commitMetadataFromFileText(fileText);
    if (metadata != null) {
      currentPatchPrefix = commitMetadataLabel(metadata, patchMetadataIndex, options.label);
      patchMetadataIndex += 1;
    }
    const cacheKey = `cmux-diff-file-${model.fileIndex}`;
    const fileDiff = options.processFile(fileText, { cacheKey, isGitDiff: true });
    annotateDiffMetadata(fileDiff, fileText);
    await enqueueFileDiff(fileDiff, currentPatchPrefix);
  }

  const response = await fetch(options.patchURL, { cache: "no-store", signal: options.signal });
  if (!response.ok) {
    throw new Error(`${options.label("loadingDiff")} (${response.status})`);
  }

  if (!response.body?.getReader) {
    throwIfAborted();
    const text = await response.text();
    throwIfAborted();
    await appendParsedPatchText(text, options, enqueueFileDiff);
    await maybeFlushPendingItems(true);
    metrics.completedAt = performance.now();
    options.onComplete({ ...metrics });
    return;
  }

  const decoder = new TextDecoder();
  const reader = response.body.getReader();
  const splitter = createStreamingPatchFileSplitter();
  const maxDecodeChunkBytes = 256 * 1024;
  while (true) {
    throwIfAborted();
    const { done, value } = await reader.read();
    if (done) {
      const tail = decoder.decode();
      if (tail.length > 0) {
        splitter.push(tail);
        await drainPatchFileSplitter(splitter, appendCompleteFileText);
      }
      break;
    }
    for (let offset = 0; offset < value.byteLength; offset += maxDecodeChunkBytes) {
      throwIfAborted();
      splitter.push(decoder.decode(value.subarray(offset, offset + maxDecodeChunkBytes), { stream: true }));
      await drainPatchFileSplitter(splitter, appendCompleteFileText);
    }
  }

  const finalFile = splitter.finish();
  throwIfAborted();
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
    gitStatusEntries: [],
    gitStatusIndexByPath: new Map(),
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
    treeRevision: 0,
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
  replaceModelItem(model, oldId, replacementItem);
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
    model.pendingItemById.delete(oldId);
    model.pendingItemById.set(newId, replacementItem);
    return undefined;
  }
  return { oldId, newId };
}

function replaceModelItem(model: StreamingDiffModel, oldId: string, replacementItem: DiffItem): void {
  const fileOrder = model.itemIdToFile.get(oldId)?.fileOrder;
  if (fileOrder == null) {
    return;
  }
  if (fileOrder < model.items.length) {
    model.items[fileOrder] = replacementItem;
  } else {
    model.pendingItems[fileOrder - model.items.length] = replacementItem;
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
      removeGitStatusEntry(model, treePath);
      markGitStatusRemoved(model, treePath);
    }
    return;
  }
  const status = gitStatusType(changeType);
  if (status === "modified") {
    if (model.gitStatusByPath.delete(treePath)) {
      removeGitStatusEntry(model, treePath);
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
  const currentIndex = model.gitStatusIndexByPath.get(treePath);
  if (currentIndex == null) {
    model.gitStatusIndexByPath.set(treePath, model.gitStatusEntries.length);
    model.gitStatusEntries.push(entry);
  } else {
    model.gitStatusEntries[currentIndex] = entry;
  }
  model.pendingGitStatusRemovePaths.delete(treePath);
  model.pendingGitStatusSetByPath.set(treePath, entry);
}

function removeGitStatusEntry(model: StreamingDiffModel, treePath: string): void {
  const index = model.gitStatusIndexByPath.get(treePath);
  if (index == null) {
    return;
  }
  const lastIndex = model.gitStatusEntries.length - 1;
  const lastEntry = model.gitStatusEntries[lastIndex];
  model.gitStatusEntries.pop();
  model.gitStatusIndexByPath.delete(treePath);
  if (index !== lastIndex && lastEntry != null) {
    model.gitStatusEntries[index] = lastEntry;
    model.gitStatusIndexByPath.set(lastEntry.path, index);
  }
}

function markGitStatusRemoved(model: StreamingDiffModel, treePath: string): void {
  model.pendingGitStatusSetByPath.delete(treePath);
  model.pendingGitStatusRemovePaths.add(treePath);
}

function createFileTreeSourceFromModel(model: StreamingDiffModel): FileTreeSource {
  const previousRevision = model.treeRevision === 0 ? undefined : model.treeRevision;
  model.treeRevision += 1;
  const source: FileTreeSource = {
    diffStats: { ...model.diffStats },
    gitStatus: model.gitStatusEntries.map((entry) => ({ ...entry })),
    gitStatusPatch: buildGitStatusPatch(model),
    pathCount: model.paths.length,
    paths: [...model.paths],
    pathToItemId: new Map(model.pathToItemId),
    previousRevision,
    revision: model.treeRevision,
    statsChanged: model.pendingStatsChanged,
    statsByPath: new Map(
      Array.from(model.statsByPath, ([path, stats]) => [path, { ...stats }]),
    ),
    treePathByItemId: new Map(model.treePathByItemId),
  };
  model.pendingStatsChanged = false;
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
  let consumed = 0;
  let searchStart = 0;
  let sawGitBoundary = false;
  const gitMarker = "diff --git ";
  const gitMarkerWithNewline = "\n" + gitMarker;
  const gitMarkerSearchTailLength = gitMarkerWithNewline.length - 1;
  const nonWhitespacePattern = /\S/;

  function nextGitBoundaryIndex(text: string, start: number): number | undefined {
    const offset = Math.max(start, 0);
    if (text.startsWith(gitMarker, offset)) {
      return offset;
    }
    const index = text.indexOf(gitMarkerWithNewline, offset);
    return index === -1 ? undefined : index + 1;
  }

  function nextGitBoundarySearchStart(text: string, start: number): number {
    return Math.max(start, text.length - gitMarkerSearchTailLength);
  }

  function takeAvailableFile(): string | null {
    if (boundaryIndex == null) {
      boundaryIndex = nextGitBoundaryIndex(buffer, Math.max(searchStart, consumed));
      if (boundaryIndex == null) {
        searchStart = nextGitBoundarySearchStart(buffer, consumed);
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
      const fileText = buffer.slice(consumed, splitBoundary);
      consumed = splitBoundary;
      compactConsumedPrefix();
      boundaryIndex = nextGitBoundaryIndex(buffer, consumed);
      searchStart = boundaryIndex == null ? consumed : boundaryIndex + 1;
      if (nonWhitespacePattern.test(fileText)) {
        return fileText;
      }
    }
  }

  return {
    push(text: string) {
      if (text.length > 0) {
        compactConsumedPrefix();
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
        consumed = 0;
        return {};
      }
      if (!sawGitBoundary) {
        const fallbackPatchContent = buffer.slice(consumed);
        buffer = "";
        consumed = 0;
        return { fallbackPatchContent };
      }
      const trailingFileText = buffer.slice(consumed);
      buffer = "";
      consumed = 0;
      return { fileText: trailingFileText };
    },
  };

  function compactConsumedPrefix(): void {
    if (consumed === 0 || consumed < 256 * 1024 || consumed * 2 < buffer.length) {
      return;
    }
    buffer = buffer.slice(consumed);
    boundaryIndex = boundaryIndex == null ? undefined : Math.max(0, boundaryIndex - consumed);
    searchStart = Math.max(0, searchStart - consumed);
    consumed = 0;
  }
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
  const searchStart = Math.max(0, minimum - 1);
  const window = text.slice(searchStart, maximum);
  let index = window.indexOf("\nFrom ");
  while (index !== -1) {
    const boundary = searchStart + index + 1;
    if (boundary >= maximum) {
      return undefined;
    }
    if (boundary < minimum) {
      index = window.indexOf("\nFrom ", index + 1);
      continue;
    }
    const lineEnd = text.indexOf("\n", boundary + 1);
    const line = text.slice(boundary, lineEnd === -1 || lineEnd > maximum ? maximum : lineEnd);
    if (commitMetadataPattern.test(line)) {
      return boundary;
    }
    index = window.indexOf("\nFrom ", index + 1);
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
  if (text.startsWith(gitMarker, offset)) {
    return offset;
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

function normalizeGitFileDiffPaths(fileDiff: any): void {
  if (fileDiff == null || typeof fileDiff !== "object") {
    return;
  }
  for (const key of ["name", "newName", "oldName", "prevName"] as const) {
    if (typeof fileDiff[key] === "string") {
      fileDiff[key] = decodeGitQuotedPath(fileDiff[key]);
    }
  }
}

export function decodeGitQuotedPath(path: string): string {
  if (!path.includes("\\")) {
    return path;
  }
  const bytes: number[] = [];
  const encoder = new TextEncoder();
  const appendText = (text: string) => bytes.push(...encoder.encode(text));
  const namedEscapes: Record<string, number> = {
    "a": 0x07,
    "b": 0x08,
    "f": 0x0c,
    "n": 0x0a,
    "r": 0x0d,
    "t": 0x09,
    "v": 0x0b,
    "\\": 0x5c,
    "\"": 0x22,
  };
  for (let index = 0; index < path.length;) {
    const codePoint = path.codePointAt(index);
    if (codePoint == null) {
      break;
    }
    const character = String.fromCodePoint(codePoint);
    if (character !== "\\" || index + 1 >= path.length) {
      appendText(character);
      index += character.length;
      continue;
    }
    const escaped = path[index + 1];
    if (escaped != null && /[0-7]/.test(escaped)) {
      let octal = escaped;
      let cursor = index + 2;
      while (octal.length < 3 && cursor < path.length && /[0-7]/.test(path[cursor] ?? "")) {
        octal += path[cursor];
        cursor += 1;
      }
      bytes.push(Number.parseInt(octal, 8));
      index = cursor;
      continue;
    }
    const escapedByte = escaped == null ? undefined : namedEscapes[escaped];
    if (escapedByte != null) {
      bytes.push(escapedByte);
      index += 2;
      continue;
    }
    appendText("\\");
    index += 1;
  }
  return new TextDecoder().decode(Uint8Array.from(bytes));
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
