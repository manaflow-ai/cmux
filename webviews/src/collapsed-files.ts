/**
 * Per-file collapse state set from a file header's caret, remembered with the
 * other viewer preferences (see viewer-prefs.ts). Entries are keyed by
 * repository root and path so a collapsed `README.md` in one repository does
 * not collapse it in another. The list is ordered oldest first and capped, so
 * the stored preference cannot grow without bound.
 */
export const MAX_COLLAPSED_FILES = 500;

const keySeparator = "\u0000";

export function collapsedFileKey(repoRoot: string, path: string): string {
  return `${repoRoot}${keySeparator}${path}`;
}

/** Returns `keys` with `key` removed, then re-added at the end when `collapsed`. */
export function withCollapsedFile(keys: readonly string[], key: string, collapsed: boolean): string[] {
  const next = keys.filter((entry) => entry !== key);
  if (collapsed) {
    next.push(key);
  }
  return next.length > MAX_COLLAPSED_FILES ? next.slice(next.length - MAX_COLLAPSED_FILES) : next;
}

export function sanitizeCollapsedFiles(raw: unknown): string[] | undefined {
  if (!Array.isArray(raw)) {
    return undefined;
  }
  const keys = raw.filter(
    (entry): entry is string => typeof entry === "string" && entry.includes(keySeparator) && entry.length <= 4096,
  );
  const unique = Array.from(new Set(keys));
  return unique.length > MAX_COLLAPSED_FILES ? unique.slice(unique.length - MAX_COLLAPSED_FILES) : unique;
}
