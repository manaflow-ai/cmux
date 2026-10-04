// The markdown page's host contract (cmux-page://cmux.markdown/, plans/cmux-next/diff-host.md S6).
// The page talks to its host only through the cmuxPage bridge (pages/shared/pageClient):
//   - `cmux.markdown.config {}` answers `MarkdownConfig`: the file, its text and hash, whether it
//     is read only, the terminal appearance (code colors) and the bases for images and libraries;
//   - `cmux.markdown.save {path, text, baseHash}` writes the file when its current hash is
//     `baseHash` (null: only when the file does not exist) and answers `{hash}`. Otherwise it fails
//     with `cmux.markdown.conflict` and details `{hash, text}` (the file now) or `{deleted: true}`;
//     a read-only file fails with `cmux.markdown.read_only`;
//   - the stream `cmux.markdown.changes` sends `MarkdownChange` when the file changes on disk
//     (including the page's own saves, which the page recognizes by hash);
//   - the stream `cmux.markdown.look` sends `MarkdownLook` when the `markdown` settings, the user's
//     markdown/theme.css or the terminal appearance change (settings.ts has the keys);
//   - `cmux.markdown.openLink {path, href}` opens a link from the file (a relative markdown file in
//     the markdown page, another file or URL through the app);
//   - the page command `save` (cmux.page.command) is Cmd-S from the app's key dispatcher.
// Resources the host serves from the page's origin (the strict PageCSP allows nothing else):
// `<assetBase><path relative to the file's folder>` for images, `<libBase>mermaid.js` and
// `<libBase>vega.js` (vega.min.js then vega-lite.min.js) for diagrams.
import type { DiffViewerAppearance } from "../../appearance";

export const MARKDOWN_CONFIG_OP = "cmux.markdown.config";
export const MARKDOWN_SAVE_OP = "cmux.markdown.save";
export const MARKDOWN_OPEN_LINK_OP = "cmux.markdown.openLink";
export const MARKDOWN_CHANGES = "cmux.markdown.changes";
export const MARKDOWN_LOOK = "cmux.markdown.look";
export const MARKDOWN_CONFLICT = "cmux.markdown.conflict";
export const MARKDOWN_READ_ONLY = "cmux.markdown.read_only";

export interface MarkdownConfig {
  /** The file's absolute path. */
  path: string;
  /** The file's text (UTF-8). A host refuses or opens read only a file that is not valid UTF-8. */
  text: string;
  /** The SHA-256 of the file's bytes, hex. */
  hash: string;
  /** The page may not save: the file is outside every workspace root (or not writable). */
  readOnly?: boolean;
  /** The terminal appearance, as the diff viewer gets it (code colors and font). */
  appearance?: DiffViewerAppearance;
  /** URL prefix of the file's folder for relative images; without it they do not load. */
  assetBase?: string;
  /** URL prefix of the diagram libraries; without it diagrams show their source only. */
  libBase?: string;
  /** The `markdown` section of cmux.json (settings.ts `MarkdownSettings`), unparsed. */
  settings?: unknown;
  /** `<cmux.json dir>/markdown/theme.css`, applied after the settings; absent when missing. */
  themeCSS?: string;
}

/**
 * A look change, on the `cmux.markdown.look` stream: the host re-sends the `markdown` settings,
 * theme.css ("" after it is deleted) or the terminal appearance when one changes. Absent keys keep
 * their current value; the page applies it in place.
 */
export interface MarkdownLook {
  settings?: unknown;
  themeCSS?: string;
  appearance?: DiffViewerAppearance;
}

export interface MarkdownSaveResult {
  hash: string;
}

/** A change of the file on disk. `text` is the new content; `deleted` when the file is gone. */
export interface MarkdownChange {
  path: string;
  hash: string | null;
  text?: string;
  deleted?: boolean;
}

/** The details of a `cmux.markdown.conflict` error. */
export interface MarkdownConflict {
  hash: string | null;
  text?: string;
  deleted?: boolean;
}

export function isMarkdownConfig(value: unknown): value is MarkdownConfig {
  const config = value as Partial<MarkdownConfig> | null;
  return typeof config?.path === "string" && typeof config.text === "string" && typeof config.hash === "string";
}

/** The image URL for `src` in the markdown file: relative paths through the host's asset base. */
export function resolveImageURL(src: string, assetBase: string | undefined): string {
  const value = src.trim();
  if (!value) return "";
  if (/^(data:image\/|blob:)/i.test(value)) return value;
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith("//")) return value;
  if (!assetBase) return "";
  // Path segments stay as the file wrote them (already percent-encoded or not), without `..` escape.
  const path = value.replace(/[?#].*$/, "").replace(/^\.\//, "");
  if (path.startsWith("/") || path.split("/").includes("..")) return "";
  return (
    assetBase +
    path
      .split("/")
      .map((segment) => encodeURIComponent(safeDecode(segment)))
      .join("/")
  );
}

function safeDecode(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}
