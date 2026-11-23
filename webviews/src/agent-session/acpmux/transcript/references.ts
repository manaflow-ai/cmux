import { type ReferenceScopeCache, type ReferenceScope } from "../conversation/bareReferences";

/// Where the transcript reads each row's bare `#N` scope (conversation/bareReferences.ts): the
/// reading of the client's rows and the cache it keeps. A new value only when a scope changed.
export type TranscriptReferences = {
  readonly cache: ReferenceScopeCache;
  readonly scopeOf: (opener: string) => ReferenceScope;
};

/// The list props a pane render rebuilds with the same rows in them (the pane's row shaping and
/// queue lists run again on every snapshot).
export const LIST_PROPS: ReadonlySet<string> = new Set([
  "rows",
  "sourceRows",
  "earlier",
  "later",
  "queuedTail",
  "queueIds",
  "queueWithdrawn",
]);

/// The same item: the same object, or a row the shaping made again with every field the same
/// (turns.ts builds the live line anew on each pass).
function sameItem(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object" || Array.isArray(a) || Array.isArray(b)) return false;
  const before = a as Record<string, unknown>;
  const after = b as Record<string, unknown>;
  const keys = Object.keys(after);
  return keys.length === Object.keys(before).length && keys.every((key) => Object.is(before[key], after[key]));
}

/// One identity compare per row; the field compare only where the objects differ (a few rows).
export function sameList(a: readonly unknown[], b: readonly unknown[]): boolean {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1)
    if (a[index] !== b[index] && !sameItem(a[index], b[index])) return false;
  return true;
}
