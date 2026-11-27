/**
 * The paused-read replica's shapes and its one search rule (cmuxterm-hq RFD 0144 piece 2, RFD 0163 pick 1): a literal,
 * case-sensitive substring, matched line by line, in files under a root. The Durable Object and the in-process store
 * both answer through `matchLines`, so a test of one is a test of the other.
 */

/** One file the walk kept: its absolute path and its text, or null when it is binary (a NUL in its first bytes). */
export interface ReplicaFile {
  readonly path: string;
  readonly text: string | null;
}

/** What a seed covered, kept beside the files. */
export interface ReplicaMeta {
  /** The directory the walk started from. */
  readonly root: string;
  /** The provider's `updatedAt` of the paused VM the walk read; the replica answers only while it is unchanged. */
  readonly marker: string;
  /** False when a bound stopped the walk (files, bytes or folders), so some files under the root were not read. */
  readonly complete: boolean;
  readonly files: number;
  readonly bytes: number;
  /** Files longer than the per-file bound: only their first bytes are searched. */
  readonly truncated: number;
  readonly seededAtMs: number;
}

export interface SearchMatch {
  readonly path: string;
  /** 1-based. */
  readonly line: number;
  /** The matching line, cut to MAX_MATCH_TEXT characters. */
  readonly text: string;
}

export const MAX_MATCH_TEXT = 400;

/** Whether `path` is `root` or lies under it. */
export const under = (root: string, path: string): boolean => {
  const prefix = root.endsWith("/") ? root : `${root}/`;
  return path === root || path.startsWith(prefix);
};

/** The matching lines of one file, appended to `out` until it holds `limit`. */
export const matchLines = (path: string, text: string, query: string, limit: number, out: SearchMatch[]): void => {
  if (out.length >= limit || !text.includes(query)) return;
  const lines = text.split("\n");
  for (let i = 0; i < lines.length && out.length < limit; i += 1) {
    const line = lines[i]!;
    if (line.includes(query)) out.push({ path, line: i + 1, text: line.length > MAX_MATCH_TEXT ? line.slice(0, MAX_MATCH_TEXT) : line });
  }
};

/** The search over a set of files, in path order, as both stores and the disk walk answer it. */
export const searchFiles = (files: Iterable<ReplicaFile>, root: string, query: string, limit: number): { matches: SearchMatch[]; scanned: number } => {
  const kept = [...files].filter((file) => under(root, file.path)).sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const matches: SearchMatch[] = [];
  for (const file of kept) {
    if (file.text !== null) matchLines(file.path, file.text, query, limit, matches);
    if (matches.length >= limit) break;
  }
  return { matches, scanned: kept.length };
};
