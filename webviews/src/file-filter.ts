import { fileName } from "./diff-stream";
import type { ViewedFileState } from "./viewed-files";

/**
 * File tree filter (GitHub "Files changed" parity): a path query, a status
 * subset, and "hide viewed". The filter hides diff sections as well as tree
 * rows, so `filterDiffItems` is the single source of the visible item list.
 */
export type DiffFileStatus = "added" | "modified" | "deleted" | "renamed";

export const allDiffFileStatuses: readonly DiffFileStatus[] = ["added", "modified", "deleted", "renamed"];

export type DiffFileFilter = {
  query: string;
  statuses: readonly DiffFileStatus[];
  hideViewed: boolean;
};

type FilterableItem = { id: string; fileDiff?: any };

export function defaultDiffFileFilter(): DiffFileFilter {
  return { query: "", statuses: allDiffFileStatuses, hideViewed: false };
}

export function isDiffFileFilterActive(filter: DiffFileFilter): boolean {
  return filter.query.trim() !== "" || filter.hideViewed || filter.statuses.length !== allDiffFileStatuses.length;
}

export function diffFileStatus(fileDiff: any): DiffFileStatus {
  switch (fileDiff?.type) {
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

/** Every whitespace-separated term must appear in the path, case-insensitively. */
export function matchesPathQuery(path: string, query: string): boolean {
  const terms = query.toLowerCase().split(/\s+/).filter((term) => term !== "");
  if (terms.length === 0) {
    return true;
  }
  const haystack = path.toLowerCase();
  return terms.every((term) => haystack.includes(term));
}

export function filterDiffItems<T extends FilterableItem>(
  items: readonly T[],
  filter: DiffFileFilter,
  viewedStateOf: (item: T) => ViewedFileState,
): T[] {
  if (!isDiffFileFilterActive(filter)) {
    return [...items];
  }
  const statuses = new Set(filter.statuses);
  return items.filter((item) => {
    const diff = item.fileDiff ?? {};
    if (!statuses.has(diffFileStatus(diff))) {
      return false;
    }
    if (filter.hideViewed && viewedStateOf(item) === "viewed") {
      return false;
    }
    const path = fileName(diff, "");
    const previousPath = typeof diff.prevName === "string" ? diff.prevName : "";
    return matchesPathQuery(path, filter.query) || (previousPath !== "" && matchesPathQuery(previousPath, filter.query));
  });
}

/** Flips one status; turning off the last enabled status re-enables all four. */
export function toggleStatusFilter(statuses: readonly DiffFileStatus[], status: DiffFileStatus): DiffFileStatus[] {
  const enabled = new Set(statuses);
  if (enabled.has(status)) {
    enabled.delete(status);
  } else {
    enabled.add(status);
  }
  if (enabled.size === 0) {
    return [...allDiffFileStatuses];
  }
  return allDiffFileStatuses.filter((candidate) => enabled.has(candidate));
}
