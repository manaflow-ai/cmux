/**
 * The "delineated diff" (Leo 2026-10-20): the viewer puts a change's files in kind order — code
 * first, then tests, mocks, docs, evals and generated — so the work a person came to read is at
 * the top and a lockfile never sits between two source files. The kinds come from the one
 * classifier the pull request card's `+/−` breakdown also reads (fileKinds.ts).
 *
 * Ordering waits for the stream to finish: moving a file while the list is still filling would
 * pull the text out from under the reader. Until then the viewer keeps the arrival order.
 */
import { fileName } from "./diff-stream";
import { fileKind, orderByKind, type FileKind } from "./fileKinds";

type KindedItem = { id: string; fileDiff?: any };

/** A diff item's path, as the file header and the filter read it. */
function diffItemPath(item: KindedItem): string {
  return fileName(item.fileDiff ?? {}, "");
}

/** A diff item's kind; `generatedPaths` is the host's declared generated list. */
export function diffItemKind(item: KindedItem, generatedPaths: ReadonlySet<string>): FileKind {
  return fileKind(diffItemPath(item), generatedPaths);
}

/**
 * `items` in kind order (fileKinds.ts `orderByKind`, which the chat's Changes view shares). The
 * sort is stable, so files of one kind keep the order they came in. Returns the same array when
 * every file is one kind, so the viewer re-renders nothing.
 */
export function orderItemsByKind<T extends KindedItem>(
  items: readonly T[],
  generatedPaths: ReadonlySet<string>,
): readonly T[] {
  return orderByKind(items, diffItemPath, generatedPaths);
}
