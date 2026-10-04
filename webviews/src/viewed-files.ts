import { callDiffComments, diffCommentsBridgeAvailable } from "./comments/bridge";
import type { DiffWrites } from "./diff-writes";
import type { DiffSource } from "./diff/generated/protocol";
import { fileName } from "./diff-stream";

/**
 * Per-file "Viewed" review state (GitHub "Files changed" parity).
 *
 * An entry records the fingerprint of the file's patch at the time it was
 * marked viewed. When the patch later changes the file shows as "changed
 * since viewed" and counts as unviewed again. Entries persist natively through
 * the `cmuxDiffComments` bridge (`viewedFiles.list` / `.set` / `.clear`),
 * keyed by (repository root, diff source identity, path); generated viewer
 * origins do not reliably persist web storage, so there is no localStorage
 * fallback and pages opened outside cmux keep session-local state only.
 */
export type ViewedFileEntry = { path: string; fingerprint: string };
export type ViewedFileState = "unviewed" | "viewed" | "changed";
export type ViewedScope = { repoRoot: string; source: string };
export type ViewedByPath = ReadonlyMap<string, ViewedFileEntry>;

type ViewedItem = { id: string; fileDiff?: any };
type ToggleableItem = ViewedItem & { collapsed?: boolean; version?: number };

export type ViewedChange = { kind: "set"; entry: ViewedFileEntry } | { kind: "clear"; path: string };

/** FNV-1a (32-bit) over the hunk text; hex so it is JSON- and path-safe. */
export function patchFingerprint(patchText: string): string {
  return fnv1a(hunkSection(patchText));
}

function hunkSection(patchText: string): string {
  const firstHunk = patchText.startsWith("@@") ? 0 : patchText.indexOf("\n@@");
  if (firstHunk >= 0) {
    return patchText.slice(firstHunk);
  }
  // Binary or metadata-only patches: hash everything except the volatile
  // `index` line (blob ids change without the content changing).
  return patchText
    .split("\n")
    .filter((line) => !line.startsWith("index "))
    .join("\n");
}

function fnv1a(text: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

/**
 * Fingerprint for a parsed file diff: the streamed patch fingerprint when the
 * stream attached one, otherwise a hash of the hunk structure and content
 * (patches parsed from a single text blob have no per-file raw text).
 */
export function fileDiffFingerprint(fileDiff: any): string {
  if (typeof fileDiff?.cmuxPatchFingerprint === "string" && fileDiff.cmuxPatchFingerprint !== "") {
    return fileDiff.cmuxPatchFingerprint;
  }
  const cacheable = fileDiff != null && typeof fileDiff === "object";
  const cached = cacheable ? fallbackFingerprints.get(fileDiff) : undefined;
  if (cached != null) {
    return cached;
  }
  const fingerprint = hunkStructureFingerprint(fileDiff);
  if (cacheable) {
    fallbackFingerprints.set(fileDiff, fingerprint);
  }
  return fingerprint;
}

/**
 * Fallback fingerprints keyed by parsed file-diff identity. A parsed diff's
 * hunks never change after parsing, and filters, progress, the tree, and the
 * header controls all ask for the same file's fingerprint on every render.
 */
const fallbackFingerprints = new WeakMap<object, string>();

function hunkStructureFingerprint(fileDiff: any): string {
  const hunks = Array.isArray(fileDiff?.hunks) ? fileDiff.hunks : [];
  const parts: string[] = [fileName(fileDiff ?? {}, ""), String(fileDiff?.type ?? "")];
  for (const hunk of hunks) {
    parts.push(`${hunk.deletionStart},${hunk.deletionCount},${hunk.additionStart},${hunk.additionCount}`);
    for (const content of hunk.hunkContent ?? []) {
      parts.push(String(content.type ?? ""), ...(Array.isArray(content.lines) ? content.lines : []));
    }
  }
  return fnv1a(parts.join("\n"));
}

/**
 * The "Viewed" marks of one scope while its stored marks load. Toggles made
 * before the stored reply arrives are kept as local edits and win over the
 * reply, so a slow `viewedFiles.list` can never undo a mark or a clear.
 */
export type ViewedSession = {
  scopeKey: string;
  viewedByPath: Map<string, ViewedFileEntry>;
  /** Path -> entry set locally, or `null` for a local clear. */
  localEdits: Map<string, ViewedFileEntry | null>;
};

/** A new scope starts empty: the previous scope's marks never apply to it. */
export function beginViewedLoad(scopeKey: string): ViewedSession {
  return { scopeKey, viewedByPath: new Map(), localEdits: new Map() };
}

export function recordViewedChange(session: ViewedSession, change: ViewedChange): ViewedSession {
  const viewedByPath = new Map(session.viewedByPath);
  const localEdits = new Map(session.localEdits);
  if (change.kind === "set") {
    viewedByPath.set(change.entry.path, change.entry);
    localEdits.set(change.entry.path, change.entry);
  } else {
    viewedByPath.delete(change.path);
    localEdits.set(change.path, null);
  }
  return { ...session, viewedByPath, localEdits };
}

/**
 * Applies a stored-marks reply for `scopeKey`, or returns `null` when the
 * reply belongs to a scope the page already left.
 */
export function applyLoadedViewed(
  session: ViewedSession,
  scopeKey: string,
  entries: readonly ViewedFileEntry[],
): ViewedSession | null {
  if (scopeKey !== session.scopeKey) {
    return null;
  }
  const viewedByPath = new Map(entries.map((entry) => [entry.path, entry] as const));
  for (const [path, entry] of session.localEdits) {
    if (entry == null) {
      viewedByPath.delete(path);
    } else {
      viewedByPath.set(path, entry);
    }
  }
  return { ...session, viewedByPath };
}

export function viewedFileState(entry: ViewedFileEntry | undefined, fingerprint: string): ViewedFileState {
  if (entry == null) {
    return "unviewed";
  }
  return entry.fingerprint === fingerprint ? "viewed" : "changed";
}

export function viewedFilePath(item: ViewedItem): string {
  return fileName(item.fileDiff ?? {}, "");
}

export function viewedStateOfItem(item: ViewedItem, viewedByPath: ViewedByPath): ViewedFileState {
  return viewedFileState(viewedByPath.get(viewedFilePath(item)), fileDiffFingerprint(item.fileDiff));
}

/**
 * Identity of the reviewed change. Typed git sources key on the repository
 * and the source kind (plus the base ref for branch diffs); patch sessions key
 * on the patch path; remote PR pages without a session key on their external
 * URL. `null` means there is nothing stable to persist against yet.
 */
export function viewedScopeFor(
  source: DiffSource | null,
  payload: { repoRoot?: unknown; externalURL?: unknown; patchURL?: unknown },
): ViewedScope | null {
  const payloadRepoRoot = nonEmptyString(payload.repoRoot);
  if (source?.kind === "unstaged" || source?.kind === "staged") {
    return { repoRoot: source.repoRoot, source: source.kind };
  }
  if (source?.kind === "branch") {
    const baseRef = nonEmptyString(source.baseRef);
    return baseRef == null ? null : { repoRoot: source.repoRoot, source: `branch:${baseRef}` };
  }
  if (source?.kind === "patch") {
    return { repoRoot: payloadRepoRoot ?? `patch:${source.path}`, source: `patch:${source.path}` };
  }
  const externalURL = nonEmptyString(payload.externalURL);
  if (externalURL != null) {
    return { repoRoot: externalURL, source: "external" };
  }
  return null;
}

export function viewedScopeKey(scope: ViewedScope | null): string {
  return scope == null ? "" : `${scope.repoRoot}\n${scope.source}`;
}

/** The repository root a `viewedScopeKey` was built from ("" for no scope). */
export function viewedScopeKeyRepoRoot(scopeKey: string): string {
  const newline = scopeKey.indexOf("\n");
  return newline < 0 ? scopeKey : scopeKey.slice(0, newline);
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

export function viewedProgress(
  items: readonly ViewedItem[],
  viewedByPath: ViewedByPath,
): { viewed: number; total: number } {
  let viewed = 0;
  for (const item of items) {
    if (viewedStateOfItem(item, viewedByPath) === "viewed") {
      viewed += 1;
    }
  }
  return { viewed, total: items.length };
}

export function formatViewedProgress(template: string, progress: { viewed: number; total: number }): string {
  return template.replace("{viewed}", String(progress.viewed)).replace("{total}", String(progress.total));
}

/**
 * Flips the viewed state of one item. Marking viewed collapses the file and
 * records the current fingerprint (a "changed since viewed" file is re-marked
 * with its new fingerprint rather than cleared); unmarking expands it.
 */
export function toggleViewedItem<T extends ToggleableItem>(
  items: readonly T[],
  viewedByPath: ViewedByPath,
  itemId: string,
): { items: T[]; viewedByPath: Map<string, ViewedFileEntry>; change: ViewedChange | null } {
  const index = items.findIndex((item) => item.id === itemId);
  const nextViewed = new Map(viewedByPath);
  if (index < 0) {
    return { items: [...items], viewedByPath: nextViewed, change: null };
  }
  const item = items[index];
  const path = viewedFilePath(item);
  const fingerprint = fileDiffFingerprint(item.fileDiff);
  const currentlyViewed = viewedFileState(viewedByPath.get(path), fingerprint) === "viewed";
  let change: ViewedChange;
  if (currentlyViewed) {
    nextViewed.delete(path);
    change = { kind: "clear", path };
  } else {
    const entry = { path, fingerprint };
    nextViewed.set(path, entry);
    change = { kind: "set", entry };
  }
  const nextItems = [...items];
  nextItems[index] = { ...item, collapsed: !currentlyViewed, version: (item.version ?? 0) + 1 };
  return { items: nextItems, viewedByPath: nextViewed, change };
}

export async function loadViewedFiles(scope: ViewedScope): Promise<ViewedFileEntry[]> {
  if (!diffCommentsBridgeAvailable()) {
    return [];
  }
  const value = await callDiffComments<{ files?: unknown }>("viewedFiles.list", { scope });
  return Array.isArray(value?.files) ? value.files.filter(isViewedFileEntry) : [];
}

export function persistViewedChange(scope: ViewedScope | null, change: ViewedChange | null, writes: DiffWrites): void {
  if (scope == null || change == null || !diffCommentsBridgeAvailable()) {
    return;
  }
  // One write in flight per file, in order; a newer mark replaces a queued one (diff-writes.ts).
  const path = change.kind === "set" ? change.entry.path : change.path;
  writes.dispatch("viewed", {
    resource: `viewed:${viewedScopeKey(scope)}:${path}`,
    write:
      change.kind === "set"
        ? { method: "viewedFiles.set", params: { scope, file: change.entry } }
        : { method: "viewedFiles.clear", params: { scope, path: change.path } },
  });
}

function isViewedFileEntry(value: unknown): value is ViewedFileEntry {
  return (
    value != null &&
    typeof value === "object" &&
    typeof (value as ViewedFileEntry).path === "string" &&
    typeof (value as ViewedFileEntry).fingerprint === "string"
  );
}
