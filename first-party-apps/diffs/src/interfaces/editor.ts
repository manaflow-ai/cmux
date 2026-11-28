// PROPOSED platform interface `cmux.editor/1` (app platform critique C1, C3).
// Vendored copy; identical in first-party-apps/{diffs,codemirror}.
//
// An editor app implements this interface in a web pane. The shell mounts it
// as a pane ("open with") or as an embed inside another app's pane (Diffs). The
// embedding app passes props and receives events; it never sees the editor's
// internals and gains no scope through it.

import type { DiffHandle } from "./diff.ts"
import type { DocHandle, DocRevision } from "./document.ts"

export const EDITOR_INTERFACE = "cmux.editor/1"

/** Optional features an editor declares in its manifest (`x-cmux-implements`). */
export type EditorCapability = "diff" | "readOnly" | "decorations" | "multiCursor"

/**
 * Text side of a diff: a document revision the owner can read, one side of a
 * file in a diff resource (read with `diff.file.read`), or literal text.
 */
export type DiffSideInput =
  | { doc: DocHandle; revision?: DocRevision }
  | { diff: DiffHandle; path: string; side: "base" | "head" }
  | { text: string; label?: string }

export interface EditorDiffInput {
  original: DiffSideInput
  modified: DiffSideInput
  layout: "sideBySide" | "inline"
  /** Path shown in headers and used to pick a language. */
  path?: string
}

export interface EditorDecoration {
  from: { line: number; column?: number }
  to?: { line: number; column?: number }
  kind: "error" | "warning" | "info" | "comment" | "highlight"
  message?: string
}

/** Props the host or the embedding app sets. Every field may change after mount. */
export interface EditorProps {
  /** Edit or view one document. Absent in diff mode. */
  doc?: DocHandle
  /** Diff mode (needs the `diff` capability). */
  diff?: EditorDiffInput
  readOnly?: boolean
  /** Overrides the language from the document type. */
  language?: string
  decorations?: EditorDecoration[]
  revealLine?: number
  /** Chrome: the embedding app may ask for no status line. */
  chrome?: "full" | "none"
}

/** Events the editor emits to the host or the embedding app. */
export type EditorEvent =
  | { type: "ready"; capabilities: EditorCapability[] }
  | { type: "selectionChanged"; line: number; column: number; selectionLength: number }
  | { type: "stateChanged"; state: EditorStateName; dirty: boolean }
  | { type: "requestSave" }
  | { type: "openDiff"; base: { doc: DocHandle; revision: DocRevision }; head: { doc: DocHandle; revision: DocRevision }; title: string }

export type EditorStateName = "loading" | "clean" | "dirty" | "saving" | "conflict" | "error" | "closed"

/**
 * Terminal-derived theme the host passes to every editor (from the Ghostty
 * config). Editors map syntax colors onto the 16-color palette and never fall
 * back to a library default selection or cursor color.
 */
export interface EditorTheme {
  appearance: "dark" | "light"
  background: string
  foreground: string
  cursor: string
  /** Selection fill. Editors draw it at the given color, not a library default. */
  selectionBackground: string
  selectionForeground?: string
  /** ANSI colors 0-15 (`#RRGGBB`). */
  palette: string[]
  fontFamily: string
  fontSize: number
  /** Accent for focus rings and the dirty dot: a non-blue Ghostty-derived color. */
  accent: string
}

/** Editor settings shared by both editor apps (`contributes.settings`). */
export interface EditorSettings {
  variant: string
  /** Empty: the terminal font. */
  fontFamily: string
  /** 0: the terminal font size. */
  fontSize: number
  minimap: boolean
  wordWrap: boolean
  lineNumbers: boolean
  tabSize: number
  renderWhitespace: "none" | "boundary" | "all"
}

export const DEFAULT_EDITOR_SETTINGS: EditorSettings = {
  variant: "statusLine",
  fontFamily: "",
  fontSize: 0,
  minimap: false,
  wordWrap: false,
  lineNumbers: true,
  tabSize: 2,
  renderWhitespace: "none"
}
