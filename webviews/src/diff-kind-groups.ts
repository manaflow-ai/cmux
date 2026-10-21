/**
 * The "delineated diff" (Leo 2026-10-20): the viewer puts a change's files in kind order — code
 * first, then tests, mocks, docs, evals and generated — so the work a person came to read is at
 * the top and a lockfile never sits between two source files. The kinds come from the one
 * classifier the pull request card's `+/−` breakdown also reads (fileKinds.ts).
 *
 * Ordering waits for the stream to finish: moving a file while the list is still filling would
 * pull the text out from under the reader. Until then the viewer keeps the arrival order.
 */
import { fileName, fileStats } from "./diff-stream";
import { FILE_KINDS, fileKind, type FileKind } from "./fileKinds";

export type DiffKindSummary = {
  readonly kind: FileKind;
  readonly files: number;
  readonly additions: number;
  readonly deletions: number;
};

type KindedItem = { id: string; fileDiff?: any };

/** A diff item's path, as the file header and the filter read it. */
export function diffItemPath(item: KindedItem): string {
  return fileName(item.fileDiff ?? {}, "");
}

/** A diff item's kind; `generatedPaths` is the host's declared generated list. */
export function diffItemKind(item: KindedItem, generatedPaths: ReadonlySet<string>): FileKind {
  return fileKind(diffItemPath(item), generatedPaths);
}

/**
 * `items` in kind order. The sort is stable, so files of one kind keep the order they came in.
 * Returns the same array when every file is one kind, so the viewer re-renders nothing.
 */
export function orderItemsByKind<T extends KindedItem>(
  items: readonly T[],
  generatedPaths: ReadonlySet<string>,
): readonly T[] {
  if (items.length < 2) return items;
  const ranked = items.map((item, index) => ({
    item,
    index,
    rank: FILE_KINDS.indexOf(diffItemKind(item, generatedPaths)),
  }));
  if (ranked.every((entry) => entry.rank === ranked[0]!.rank)) return items;
  ranked.sort((left, right) => left.rank - right.rank || left.index - right.index);
  return ranked.map((entry) => entry.item);
}

/** What each kind in `items` adds up to, in ``FILE_KINDS`` order, leaving out the kinds it has none of. */
export function diffKindSummaries(
  items: readonly KindedItem[],
  generatedPaths: ReadonlySet<string>,
): DiffKindSummary[] {
  const totals = new Map<FileKind, { files: number; additions: number; deletions: number }>();
  for (const item of items) {
    const kind = diffItemKind(item, generatedPaths);
    const stats = fileStats(item.fileDiff ?? {});
    const total = totals.get(kind) ?? { files: 0, additions: 0, deletions: 0 };
    total.files += 1;
    total.additions += stats.added;
    total.deletions += stats.deleted;
    totals.set(kind, total);
  }
  return FILE_KINDS.filter((kind) => totals.has(kind)).map((kind) => ({ kind, ...totals.get(kind)! }));
}
