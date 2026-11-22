// Monaco implementation of the shared EditorAdapter. Only the editor core,
// a few editing contributions and tokenizer-only languages are bundled (no
// language services, no CDN, no network).

import * as monaco from "monaco-editor/editor/editor.api.js"
// The package exports map has no CSS entries; import the icon font stylesheet by path.
import "../node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon.css"
import "monaco-editor/editor/contrib/bracketMatching/browser/bracketMatching.js"
import "monaco-editor/editor/contrib/caretOperations/browser/caretOperations.js"
import "monaco-editor/editor/contrib/clipboard/browser/clipboard.js"
import "monaco-editor/editor/contrib/comment/browser/comment.js"
import "monaco-editor/editor/contrib/cursorUndo/browser/cursorUndo.js"
import "monaco-editor/editor/contrib/find/browser/findController.js"
import "monaco-editor/editor/contrib/folding/browser/folding.js"
import "monaco-editor/editor/contrib/indentation/browser/indentation.js"
import "monaco-editor/editor/contrib/linesOperations/browser/linesOperations.js"
import "monaco-editor/editor/contrib/multicursor/browser/multicursor.js"
import "monaco-editor/editor/contrib/smartSelect/browser/smartSelect.js"
import "monaco-editor/editor/contrib/wordHighlighter/browser/wordHighlighter.js"
import "monaco-editor/editor/contrib/wordOperations/browser/wordOperations.js"
import "monaco-editor/languages/definitions/cpp/register.js"
import "monaco-editor/languages/definitions/css/register.js"
import "monaco-editor/languages/definitions/dockerfile/register.js"
import "monaco-editor/languages/definitions/go/register.js"
import "monaco-editor/languages/definitions/html/register.js"
import "monaco-editor/languages/definitions/ini/register.js"
import "monaco-editor/languages/definitions/java/register.js"
import "monaco-editor/languages/definitions/javascript/register.js"
import "monaco-editor/languages/definitions/kotlin/register.js"
import "monaco-editor/languages/definitions/less/register.js"
import "monaco-editor/languages/definitions/markdown/register.js"
import "monaco-editor/languages/definitions/python/register.js"
import "monaco-editor/languages/definitions/ruby/register.js"
import "monaco-editor/languages/definitions/rust/register.js"
import "monaco-editor/languages/definitions/scss/register.js"
import "monaco-editor/languages/definitions/shell/register.js"
import "monaco-editor/languages/definitions/sql/register.js"
import "monaco-editor/languages/definitions/swift/register.js"
import "monaco-editor/languages/definitions/typescript/register.js"
import "monaco-editor/languages/definitions/xml/register.js"
import "monaco-editor/languages/definitions/yaml/register.js"
import type { TextEdit } from "../src/interfaces/document.ts"
import type { EditorSettings, EditorTheme } from "../src/interfaces/editor.ts"
import type { DiffMountOptions, DocMountOptions, EditorAdapter } from "../src/shared/adapter.ts"
import { chromeColors, fontFamily, fontSize, mix, syntaxColors } from "../src/shared/theme.ts"

// The editor worker is a separate same-origin file (CSP `default-src 'self'`).
;(globalThis as { MonacoEnvironment?: unknown }).MonacoEnvironment = { getWorker: () => new Worker("editor-worker.js", { type: "module" }) }

const THEME = "cmux-terminal"
const bare = (c: string) => c.replace("#", "")

/** Monarch tokens -> terminal palette roles. No library default colors remain (inherit: false). */
function defineTheme(theme: EditorTheme) {
  const s = syntaxColors(theme)
  const c = chromeColors(theme)
  const rule = (token: string, color: string, fontStyle?: string) => ({ token, foreground: bare(color), fontStyle })
  monaco.editor.defineTheme(THEME, {
    base: theme.appearance === "dark" ? "vs-dark" : "vs",
    inherit: false,
    rules: [
      rule("", theme.foreground),
      rule("comment", s.comment, "italic"),
      rule("string", s.string),
      rule("string.escape", s.regexp),
      rule("number", s.number),
      rule("keyword", s.keyword),
      rule("keyword.flow", s.keyword),
      rule("type", s.type),
      rule("type.identifier", s.type),
      rule("identifier", s.variable),
      rule("delimiter", s.operator),
      rule("operator", s.operator),
      rule("regexp", s.regexp),
      rule("tag", s.tag),
      rule("metatag", s.tag),
      rule("attribute.name", s.attribute),
      rule("attribute.value", s.string),
      rule("variable", s.variable),
      rule("variable.predefined", s.constant),
      rule("constant", s.constant),
      rule("predefined", s.function),
      rule("annotation", s.constant),
      rule("emphasis", theme.foreground, "italic"),
      rule("strong", theme.foreground, "bold"),
      rule("invalid", s.invalid)
    ],
    colors: {
      "editor.background": c.background,
      "editor.foreground": c.foreground,
      "editorCursor.foreground": c.cursor,
      "editor.selectionBackground": c.selection,
      "editor.inactiveSelectionBackground": c.inactiveSelection,
      "editor.selectionHighlightBackground": c.match,
      "editor.wordHighlightBackground": c.match,
      "editor.wordHighlightStrongBackground": c.match,
      "editor.findMatchBackground": c.matchStrong,
      "editor.findMatchHighlightBackground": c.match,
      "editor.findRangeHighlightBackground": c.line,
      "editor.lineHighlightBackground": c.line,
      "editor.lineHighlightBorder": c.line,
      "editorLineNumber.foreground": c.gutter,
      "editorLineNumber.activeForeground": c.gutterActive,
      "editorGutter.background": c.background,
      "editorIndentGuide.background1": c.line,
      "editorIndentGuide.activeBackground1": c.border,
      "editorBracketMatch.background": c.match,
      "editorBracketMatch.border": c.matchStrong,
      "editorWidget.background": c.statusBackground,
      "editorWidget.foreground": c.foreground,
      "editorWidget.border": c.border,
      "editorHoverWidget.background": c.statusBackground,
      "editorHoverWidget.border": c.border,
      "input.background": c.background,
      "input.foreground": c.foreground,
      "input.border": c.border,
      "inputOption.activeBorder": c.accent,
      "inputOption.activeBackground": c.match,
      "focusBorder": c.accent,
      "list.activeSelectionBackground": c.match,
      "list.focusBackground": c.match,
      "list.hoverBackground": c.line,
      "list.highlightForeground": c.accent,
      "editorSuggestWidget.selectedBackground": c.match,
      "editorSuggestWidget.highlightForeground": c.accent,
      // Bracket pair colors default to a palette with blue; every level uses the operator color.
      ...Object.fromEntries([1, 2, 3, 4, 5, 6].map((i) => [`editorBracketHighlight.foreground${i}`, s.operator])),
      "editorBracketHighlight.unexpectedBracket.foreground": s.invalid,
      "editorLink.activeForeground": s.link,
      "textLink.foreground": s.link,
      "scrollbarSlider.background": mix(c.background, c.foreground, 0.15) + "80",
      "scrollbarSlider.hoverBackground": mix(c.background, c.foreground, 0.25) + "80",
      "scrollbarSlider.activeBackground": mix(c.background, c.foreground, 0.35) + "80",
      "editorOverviewRuler.border": c.background,
      "diffEditor.insertedTextBackground": c.addedText,
      "diffEditor.removedTextBackground": c.removedText,
      "diffEditor.insertedLineBackground": c.addedBand,
      "diffEditor.removedLineBackground": c.removedBand,
      "diffEditorGutter.insertedLineBackground": c.addedBand,
      "diffEditorGutter.removedLineBackground": c.removedBand,
      "diffEditor.diagonalFill": c.border,
      "diffEditor.unchangedRegionBackground": c.statusBackground,
      "diffEditor.unchangedRegionForeground": c.muted,
      "diffEditor.move.border": c.border,
      "editorStickyScroll.background": c.background,
      "minimap.background": c.background,
      "minimapSlider.background": mix(c.background, c.foreground, 0.15) + "60"
    }
  })
  monaco.editor.setTheme(THEME)
}

/** Monaco has no tokenizer-only JSON language bundled here; JavaScript tokens read well for JSON. */
const monacoLanguage = (id: string) => (id === "json" ? "javascript" : monaco.languages.getLanguages().some((l) => l.id === id) ? id : "plaintext")

function options(theme: EditorTheme, settings: EditorSettings): monaco.editor.IEditorOptions {
  return {
    fontFamily: fontFamily(theme, settings),
    fontSize: fontSize(theme, settings),
    lineHeight: Math.round(fontSize(theme, settings) * 1.5),
    minimap: { enabled: settings.minimap },
    wordWrap: settings.wordWrap ? "on" : "off",
    lineNumbers: settings.lineNumbers ? "on" : "off",
    renderWhitespace: settings.renderWhitespace,
    scrollBeyondLastLine: false,
    automaticLayout: true,
    contextmenu: false,
    bracketPairColorization: { enabled: false },
    guides: { bracketPairs: false },
    fixedOverflowWidgets: true,
    overviewRulerBorder: false,
    renderLineHighlight: "all",
    padding: { top: 6 },
    stickyScroll: { enabled: false }
  }
}

export function createMonacoAdapter(): EditorAdapter {
  let editor: monaco.editor.IStandaloneCodeEditor | null = null
  let diff: monaco.editor.IStandaloneDiffEditor | null = null
  let models: monaco.editor.ITextModel[] = []
  let applyingHost = false

  function destroy() {
    editor?.dispose()
    diff?.dispose()
    for (const m of models) m.dispose()
    editor = null
    diff = null
    models = []
  }

  return {
    name: "Monaco",
    capabilities: ["diff", "readOnly", "multiCursor", "decorations"],
    mountDoc(el: HTMLElement, o: DocMountOptions) {
      destroy()
      defineTheme(o.theme)
      const model = monaco.editor.createModel(o.text, monacoLanguage(o.language))
      model.updateOptions({ tabSize: o.settings.tabSize, insertSpaces: true })
      models = [model]
      editor = monaco.editor.create(el, { ...options(o.theme, o.settings), model, theme: THEME, readOnly: o.readOnly })
      model.onDidChangeContent(() => {
        if (!applyingHost) o.onChange(model.getValue())
      })
      editor.onDidChangeCursorSelection((e) => {
        const sel = e.selection
        o.onSelection({ line: sel.positionLineNumber, column: sel.positionColumn, length: Math.abs(model.getOffsetAt(sel.getEndPosition()) - model.getOffsetAt(sel.getStartPosition())) })
      })
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => o.onSave())
      o.onSelection({ line: 1, column: 1, length: 0 })
    },
    setView(text: string, edits: TextEdit[]) {
      const model = editor?.getModel()
      if (!model) return
      applyingHost = true
      try {
        // `edits` apply in order, each against the previous result.
        for (const e of edits) {
          const start = model.getPositionAt(e.from)
          const end = model.getPositionAt(e.to)
          model.applyEdits([{ range: new monaco.Range(start.lineNumber, start.column, end.lineNumber, end.column), text: e.text }])
        }
        if (model.getValue() !== text) model.setValue(text)
      } finally {
        applyingHost = false
      }
    },
    setReadOnly(readOnly: boolean) {
      editor?.updateOptions({ readOnly })
    },
    setLanguage(id: string) {
      const model = editor?.getModel()
      if (model) monaco.editor.setModelLanguage(model, monacoLanguage(id))
    },
    setAppearance(theme: EditorTheme, settings: EditorSettings) {
      defineTheme(theme)
      editor?.updateOptions(options(theme, settings))
      diff?.updateOptions(options(theme, settings))
    },
    mountDiff(el: HTMLElement, o: DiffMountOptions) {
      destroy()
      defineTheme(o.theme)
      const lang = monacoLanguage(o.language)
      const original = monaco.editor.createModel(o.original, lang)
      const modified = monaco.editor.createModel(o.modified, lang)
      models = [original, modified]
      diff = monaco.editor.createDiffEditor(el, {
        ...options(o.theme, o.settings),
        theme: THEME,
        readOnly: true,
        originalEditable: false,
        renderSideBySide: o.layout === "sideBySide",
        useInlineViewWhenSpaceIsLimited: false,
        renderOverviewRuler: false,
        hideUnchangedRegions: { enabled: true, contextLineCount: 3, minimumLineCount: 6 }
      })
      diff.setModel({ original, modified })
    },
    setDiffLayout(layout) {
      diff?.updateOptions({ renderSideBySide: layout === "sideBySide" })
    },
    focus() {
      ;(editor ?? diff?.getModifiedEditor())?.focus()
    },
    destroy
  }
}
