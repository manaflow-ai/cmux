// What the shared controller needs from an editor library (shared by the
// editor apps; identical copies in first-party-apps/codemirror).

import type { EditorCapability, EditorSettings, EditorTheme } from "../interfaces/editor.ts"
import type { TextEdit } from "../interfaces/document.ts"

export interface Selection {
  line: number
  column: number
  length: number
}

export interface DocMountOptions {
  text: string
  language: string
  readOnly: boolean
  theme: EditorTheme
  settings: EditorSettings
  /** User edits only; programmatic `setView` must not call it. */
  onChange(text: string): void
  onSelection(sel: Selection): void
  /** Cmd-S inside the editor. */
  onSave(): void
}

export interface DiffMountOptions {
  original: string
  modified: string
  layout: "sideBySide" | "inline"
  language: string
  theme: EditorTheme
  settings: EditorSettings
}

export interface EditorAdapter {
  /** Library name for the status line ("CodeMirror"). */
  readonly name: string
  readonly capabilities: EditorCapability[]
  mountDoc(el: HTMLElement, o: DocMountOptions): void
  /** Replace the text with `text` by applying `edits`, keeping the cursor where possible. */
  setView(text: string, edits: TextEdit[]): void
  setReadOnly(readOnly: boolean): void
  setLanguage(language: string): void
  setAppearance(theme: EditorTheme, settings: EditorSettings): void
  mountDiff(el: HTMLElement, o: DiffMountOptions): void
  setDiffLayout(layout: "sideBySide" | "inline"): void
  focus(): void
  destroy(): void
}
