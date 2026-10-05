// The empty-state host ops of the diff and markdown pages (plans/cmux-next/diff-host.md, S4 and S6,
// "Empty state"). A page with nothing to show (the diff page without a repository, the markdown
// page without a file) asks its host for recent items and lets the user pick one:
//   - `cmux.diff.recents {}` / `cmux.markdown.recents {}` answer `RecentsResult`, newest first;
//   - `cmux.diff.chooseFolder {start?}` / `cmux.markdown.chooseFile {start?}` open the host's
//     picker (the app's palette folder and file picker) and answer `{path}`, or null on cancel;
//   - `cmux.diff.open {path, source}` answers the page config `cmux.diff.config` would now answer
//     for that repository (the host resolves `path` to its git top level and records it as recent),
//     or fails with `cmux.diff.not_a_repo`;
//   - `cmux.markdown.open {path}` answers the `MarkdownConfig` of that file (recorded as recent), or
//     fails with `cmux.markdown.not_markdown` or `cmux.markdown.not_found`;
//   - the code editor (pages/editor/host.ts) has the same pair: `cmux.editor.recents {}` and
//     `cmux.editor.chooseFile {start?}` (any file), then `cmux.editor.open {path}`.
// A host signals the empty state with `{pick: true}` from `cmux.diff.config` (or a payload without
// `repoRoot` and `sessionSource`) and from `cmux.markdown.config` (or a config without `path`).
// `cmux.picker.list` and `cmux.picker.locations` are the data sources of the in-page fallback
// picker (PathPicker.tsx); the dev server serves them, the app does not need to.
import type { DiffSource } from "../diff/generated/protocol";

export const DIFF_RECENTS_OP = "cmux.diff.recents";
export const DIFF_CHOOSE_FOLDER_OP = "cmux.diff.chooseFolder";
export const DIFF_OPEN_OP = "cmux.diff.open";
export const DIFF_NOT_A_REPO = "cmux.diff.not_a_repo";
export const MARKDOWN_RECENTS_OP = "cmux.markdown.recents";
export const MARKDOWN_CHOOSE_FILE_OP = "cmux.markdown.chooseFile";
export const MARKDOWN_OPEN_OP = "cmux.markdown.open";
export const MARKDOWN_NOT_MARKDOWN = "cmux.markdown.not_markdown";
export const EDITOR_RECENTS_OP = "cmux.editor.recents";
export const EDITOR_CHOOSE_FILE_OP = "cmux.editor.chooseFile";
export const PICKER_LIST_OP = "cmux.picker.list";
export const PICKER_LOCATIONS_OP = "cmux.picker.locations";

/** The source kinds the diff empty state offers; `uncommitted` is a branch session against HEAD. */
export type EmptySourceKind = "branch" | "uncommitted" | "staged" | "unstaged";

/** One recent repository or file. */
export interface RecentItem {
  /** Absolute path: the repository's top level, or the markdown file. */
  path: string;
  /** Display name; the last path component when absent. */
  name?: string;
  /** When it was last opened, milliseconds since the epoch. */
  openedAt: number;
  /** Diff only: the source it was last opened with, preselected after choosing it. */
  source?: EmptySourceKind;
  /** Diff only: the repository's current branch, shown after its path. */
  branch?: string;
}

export interface RecentsResult {
  items: RecentItem[];
}

export interface ChooseResult {
  path: string;
}

export interface DiffOpenParams {
  path: string;
  source: DiffSource;
}

/** One row of a `cmux.picker.list` listing. */
export interface PickerEntry {
  name: string;
  path: string;
  kind: "dir" | "file";
  /** A folder that is a git repository's top level. */
  git?: boolean;
}

/**
 * `cmux.picker.list {path, mode, hidden}`: one directory level. `path` null lists the start folder
 * (home), `"~"` home.
 */
export interface PickerListing {
  path: string;
  /** The folder above, or null at the top of what the host lists. */
  parent: string | null;
  /** The user's home folder, for `~` and the breadcrumb. */
  home: string | null;
  entries: PickerEntry[];
}

/** `file` lists markdown files (the markdown page), `anyFile` every file (the code editor). */
export type PickerMode = "folder" | "file" | "anyFile";

export function isPickerListing(value: unknown): value is PickerListing {
  const listing = value as Partial<PickerListing> | null;
  return typeof listing?.path === "string" && Array.isArray(listing.entries);
}

/** The recent items of a `*.recents` answer, newest first; malformed rows are dropped. */
export function parseRecents(value: unknown): RecentItem[] {
  const items = (value as Partial<RecentsResult> | null)?.items;
  if (!Array.isArray(items)) return [];
  return items
    .filter(
      (item): item is RecentItem =>
        !!item &&
        typeof item.path === "string" &&
        item.path !== "" &&
        typeof item.openedAt === "number" &&
        Number.isFinite(item.openedAt),
    )
    .sort((a, b) => b.openedAt - a.openedAt);
}

/** The chosen path of a `choose*` answer, or null when the user cancelled. */
export function parseChosenPath(value: unknown): string | null {
  const path = (value as Partial<ChooseResult> | null)?.path;
  return typeof path === "string" && path !== "" ? path : null;
}

/** The last path component. */
export function baseName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

/** `path` with the home folder written as `~`. */
export function tildePath(path: string, home: string | null | undefined): string {
  if (!home) return path;
  const base = home.replace(/\/+$/, "");
  if (path === base) return "~";
  return path.startsWith(`${base}/`) ? `~${path.slice(base.length)}` : path;
}

/** Whether the diff page config says the page has no repository yet. */
export function diffConfigNeedsPick(config: unknown): boolean {
  const value = config as { pick?: unknown; payload?: { repoRoot?: unknown; sessionSource?: unknown } } | null;
  if (value?.pick === true) return true;
  const payload = value?.payload;
  const repo = typeof payload?.repoRoot === "string" && payload.repoRoot !== "";
  return !repo && (payload?.sessionSource == null || typeof payload.sessionSource !== "object");
}

/** Whether the markdown page config says the page has no file yet. */
export function markdownConfigNeedsPick(config: unknown): boolean {
  const value = config as { pick?: unknown; path?: unknown } | null;
  return value?.pick === true || (value != null && typeof value === "object" && value.path == null);
}

/** The session source of an empty-state source choice for `repoRoot`. */
export function emptySource(kind: EmptySourceKind, repoRoot: string, baseRef?: string): DiffSource {
  switch (kind) {
    case "uncommitted":
      return { kind: "branch", repoRoot, baseRef: "HEAD" };
    case "staged":
    case "unstaged":
      return { kind, repoRoot };
    default:
      return baseRef ? { kind: "branch", repoRoot, baseRef } : { kind: "branch", repoRoot };
  }
}

/** Whether `name` is a markdown file the markdown page opens. */
export function isMarkdownName(name: string): boolean {
  return /\.(md|markdown|mdx|mdown|mkd)$/i.test(name);
}
