// `file.search {path, query, limit}`, answered by the session host's shared git and
// file-search service in the cmux binary (spec S8): files under the session's folder whose
// path matches a query, best first. The pane only renders what comes back; ranking is the
// service's. A folder outside a repository fails with `validation.invalid`.

/// One match: a path relative to the result's root, '/'-separated, and the indexes into it of
/// the characters the query matched, for highlighting.
export type FileMatch = { path: string; matches?: number[] };
export type FileSearchResult = { root: string; results: FileMatch[]; truncated?: boolean };

export type FileSearchSource = (query: string) => Promise<unknown>;

/// How many results the palette asks for (the service's default; it allows up to 200).
export const FILE_SEARCH_LIMIT = 50;

/// The failure code for a folder the service can't search: not in a repository.
export const OUTSIDE_REPOSITORY = "validation.invalid";

/// The failure's code, when the reply carried one.
export function failureCode(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : undefined;
}

/// A reply in the shape above, or undefined for anything else; malformed entries are dropped.
export function readFileSearch(value: unknown): FileSearchResult | undefined {
  const reply = value as Partial<FileSearchResult> | null;
  if (!reply || typeof reply.root !== "string" || !Array.isArray(reply.results)) return undefined;
  const results: FileMatch[] = [];
  for (const entry of reply.results as unknown[]) {
    const match = entry as Partial<FileMatch> | null;
    if (!match || typeof match.path !== "string" || !match.path) continue;
    const matches = Array.isArray(match.matches)
      ? match.matches.filter(
          (index): index is number => Number.isInteger(index) && index >= 0 && index < match.path!.length,
        )
      : undefined;
    results.push(matches?.length ? { path: match.path, matches } : { path: match.path });
  }
  return { root: reply.root, results, truncated: reply.truncated === true };
}

/// A path split for display: its folder (no trailing slash), then its name, each as runs marked matched or not.
export function matchRuns(path: string, matches: number[] = []): { dir: Run[]; name: Run[] } {
  const hit = new Set(matches);
  const slash = path.lastIndexOf("/");
  const runs = (from: number, to: number) => {
    const out: Run[] = [];
    for (let index = from; index < to; index++) {
      const matched = hit.has(index);
      const last = out[out.length - 1];
      if (last && last.matched === matched) last.text += path[index];
      else out.push({ text: path[index]!, matched });
    }
    return out;
  };
  // The folder shows without its trailing slash; the name sits beside it.
  return { dir: runs(0, Math.max(slash, 0)), name: runs(slash + 1, path.length) };
}

export type Run = { text: string; matched: boolean };
