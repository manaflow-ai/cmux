// The code editor page's host contract (cmux-page://cmux.editor/, plans/cmux-next/diff-host.md
// "Editor page"). The page talks to its host only through the cmuxPage bridge (pages/shared/pageClient):
//   - `cmux.editor.config {}` answers `EditorConfig` (the file, its text and hash, whether it is read
//     only and why, the look), or `{pick: true}` when the page has no file yet (the empty state);
//   - `cmux.editor.open {path}` answers the `EditorConfig` of another file (the empty state, a
//     followed link); the page's file is that file from then on. Errors `cmux.editor.not_found`,
//     `cmux.editor.not_file` (a folder), `cmux.editor.too_large`;
//   - `cmux.editor.save {path, text, baseHash}` writes `text` as UTF-8 when the file's hash is
//     `baseHash` (null: only when the file does not exist) and answers `{hash}`; a file whose bytes
//     already equal `text` is not written. Refused with `cmux.editor.conflict` `{hash, text}` or
//     `{deleted: true}`, and `cmux.editor.read_only` for a read-only file;
//   - `cmux.editor.setPreference {key, value}` stores one `editor.*` settings key (a toolbar toggle:
//     word wrap, minimap); the host writes the settings store and re-sends the look. Never web storage;
//   - `cmux.editor.recents {}` and `cmux.editor.chooseFile {start?}` for the empty state (viewer-empty);
//   - `cmux.editor.openLink {path, href}` opens a link the user followed in the file (http(s): a cmux
//     browser tab, mailto:/tel: the system handler);
//   - streams `cmux.editor.changes` (`EditorChange`, a disk change of the page's file, its own saves
//     included) and `cmux.editor.look` (`EditorLook`, settings, theme.css, appearance or languages);
//   - the host may call the page: `cmux.editor.flush {}` saves pending edits now and answers
//     `{dirty}` (false when everything is on disk), before the host closes the tab or quits;
//   - page commands (cmux.page.command) from the app's key dispatcher: `save`, `find`, `findNext`,
//     `findPrevious`, `useSelectionForFind`, `hideFind`, `zoomIn`, `zoomOut`, `zoomReset`, and
//     `editorAction` with `text` a Monaco action id from `EDITOR_ACTIONS` (keys.ts).
// The text is the file's bytes decoded as UTF-8 with nothing removed: a BOM stays as U+FEFF and line
// endings stay as they are, so writing the saved `text` as UTF-8 reproduces the file byte for byte.
import type { DiffViewerAppearance } from "../../appearance";

export const EDITOR_CONFIG_OP = "cmux.editor.config";
export const EDITOR_OPEN_OP = "cmux.editor.open";
export const EDITOR_SAVE_OP = "cmux.editor.save";
export const EDITOR_SET_PREFERENCE_OP = "cmux.editor.setPreference";
export const EDITOR_RECENTS_OP = "cmux.editor.recents";
export const EDITOR_CHOOSE_FILE_OP = "cmux.editor.chooseFile";
export const EDITOR_OPEN_LINK_OP = "cmux.editor.openLink";
export const EDITOR_FLUSH_OP = "cmux.editor.flush";
export const EDITOR_CHANGES = "cmux.editor.changes";
export const EDITOR_LOOK = "cmux.editor.look";
export const EDITOR_CONFLICT = "cmux.editor.conflict";
export const EDITOR_READ_ONLY = "cmux.editor.read_only";
export const EDITOR_NOT_FOUND = "cmux.editor.not_found";
export const EDITOR_NOT_FILE = "cmux.editor.not_file";
export const EDITOR_TOO_LARGE = "cmux.editor.too_large";

/** Why a file opens read only. */
export type ReadOnlyReason = "outside" | "encoding" | "binary" | "permission";

export interface EditorFile {
  /** The file's absolute path. */
  path: string;
  /** The file's bytes decoded as UTF-8, nothing removed (a BOM stays as U+FEFF). */
  text: string;
  /** The SHA-256 of the file's bytes, hex. */
  hash: string;
  /** The file's size in bytes (the large-file threshold compares it). */
  size?: number;
  /** The page may not save. */
  readOnly?: boolean;
  /** Why it is read only: outside every workspace root, not valid UTF-8, binary, not writable. */
  readOnlyReason?: ReadOnlyReason;
}

/** What `cmux.editor.config` and `cmux.editor.open` answer. */
export interface EditorConfig extends EditorFile {
  /** The terminal appearance, as the diff viewer gets it (code font, palette, colors). */
  appearance?: DiffViewerAppearance;
  /** The `editor` settings section (settings.ts `EditorSettings`), unparsed. */
  settings?: unknown;
  /** The shared `appearance.syntaxTheme` value: "terminal" (default) or Shiki theme names. */
  syntaxTheme?: unknown;
  /** `<config dir>/editor/theme.css`, applied after the settings; absent when missing. */
  themeCSS?: string;
  /** The user languages folder `<config dir>/diff/languages/`, as the diff viewer gets it. */
  languages?: unknown;
  /** A screen reader is running (VoiceOver): `editor.accessibilitySupport` "auto" turns Monaco's on. */
  screenReader?: boolean;
}

/** A look change on `cmux.editor.look`. Absent keys keep their value; "" clears theme.css. */
export interface EditorLook {
  settings?: unknown;
  syntaxTheme?: unknown;
  themeCSS?: string;
  appearance?: DiffViewerAppearance;
  languages?: unknown;
  screenReader?: boolean;
}

export interface EditorSaveResult {
  hash: string;
}

/** A disk change of the page's file. `text` is the new content; `deleted` when the file is gone. */
export interface EditorChange {
  path: string;
  hash: string | null;
  text?: string;
  deleted?: boolean;
}

/** The details of a `cmux.editor.conflict` error. */
export interface EditorConflict {
  hash: string | null;
  text?: string;
  deleted?: boolean;
}

export function isEditorConfig(value: unknown): value is EditorConfig {
  const config = value as Partial<EditorConfig> | null;
  return typeof config?.path === "string" && typeof config.text === "string" && typeof config.hash === "string";
}

/** Whether the config says the page has no file yet (the empty state). */
export function editorConfigNeedsPick(value: unknown): boolean {
  const config = value as { pick?: unknown; path?: unknown } | null;
  return config?.pick === true || (config != null && typeof config === "object" && config.path == null);
}
