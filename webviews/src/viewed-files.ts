import { callDiffComments, diffCommentsBridgeAvailable } from "./comments/bridge";
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

export type ViewedChange =
  | { kind: "set"; entry: ViewedFileEntry }
  | { kind: "clear"; path: string };

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

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

export function viewedProgress(items: readonly ViewedItem[], viewedByPath: ViewedByPath): { viewed: number; total: number } {
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

export function persistViewedChange(scope: ViewedScope | null, change: ViewedChange | null): void {
  if (scope == null || change == null || !diffCommentsBridgeAvailable()) {
    return;
  }
  const request = change.kind === "set"
    ? callDiffComments<unknown>("viewedFiles.set", { scope, file: change.entry })
    : callDiffComments<unknown>("viewedFiles.clear", { scope, path: change.path });
  request.catch((error) => console.warn("cmux diff viewed state save failed", error));
}

function isViewedFileEntry(value: unknown): value is ViewedFileEntry {
  return value != null && typeof value === "object"
    && typeof (value as ViewedFileEntry).path === "string"
    && typeof (value as ViewedFileEntry).fingerprint === "string";
}
