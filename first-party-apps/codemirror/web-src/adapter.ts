// CodeMirror 6 implementation of the shared EditorAdapter.

import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete"
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands"
import { css } from "@codemirror/lang-css"
import { html } from "@codemirror/lang-html"
import { javascript } from "@codemirror/lang-javascript"
import { json } from "@codemirror/lang-json"
import { markdown } from "@codemirror/lang-markdown"
import { python } from "@codemirror/lang-python"
import { rust } from "@codemirror/lang-rust"
import { bracketMatching, foldGutter, HighlightStyle, indentOnInput, indentUnit, syntaxHighlighting } from "@codemirror/language"
import { MergeView, unifiedMergeView } from "@codemirror/merge"
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search"
import { Annotation, Compartment, EditorState, Prec, type Extension } from "@codemirror/state"
import { drawSelection, dropCursor, EditorView, highlightActiveLine, highlightActiveLineGutter, highlightSpecialChars, keymap, lineNumbers, rectangularSelection } from "@codemirror/view"
import { tags } from "@lezer/highlight"
import type { TextEdit } from "../src/interfaces/document.ts"
import type { EditorSettings, EditorTheme } from "../src/interfaces/editor.ts"
import type { DiffMountOptions, DocMountOptions, EditorAdapter } from "../src/shared/adapter.ts"
import { chromeColors, fontFamily, fontSize, syntaxColors } from "../src/shared/theme.ts"

/** Marks transactions the controller makes, so they are not reported as user edits. */
const fromHost = Annotation.define<boolean>()

function languageExtension(id: string): Extension {
  switch (id) {
    case "typescript":
      return javascript({ typescript: true, jsx: true })
    case "javascript":
      return javascript({ jsx: true })
    case "json":
      return json()
    case "markdown":
      return markdown()
    case "python":
      return python()
    case "rust":
      return rust()
    case "css":
    case "scss":
    case "less":
      return css()
    case "html":
    case "xml":
      return html()
    default:
      return []
  }
}

function highlightStyle(theme: EditorTheme) {
  const c = syntaxColors(theme)
  return HighlightStyle.define([
    { tag: [tags.keyword, tags.controlKeyword, tags.moduleKeyword, tags.operatorKeyword], color: c.keyword },
    { tag: [tags.string, tags.special(tags.string), tags.character], color: c.string },
    { tag: [tags.number, tags.bool, tags.null], color: c.number },
    { tag: [tags.comment, tags.lineComment, tags.blockComment, tags.docComment], color: c.comment, fontStyle: "italic" },
    { tag: [tags.function(tags.variableName), tags.function(tags.propertyName), tags.macroName], color: c.function },
    { tag: [tags.typeName, tags.className, tags.namespace], color: c.type },
    { tag: [tags.constant(tags.variableName), tags.atom, tags.self], color: c.constant },
    { tag: [tags.propertyName, tags.labelName], color: c.property },
    { tag: [tags.tagName], color: c.tag },
    { tag: [tags.attributeName], color: c.attribute },
    { tag: [tags.regexp, tags.escape], color: c.regexp },
    { tag: [tags.operator, tags.punctuation, tags.bracket], color: c.operator },
    { tag: [tags.heading], color: c.heading, fontWeight: "bold" },
    { tag: [tags.link, tags.url], color: c.link, textDecoration: "underline" },
    { tag: [tags.emphasis], fontStyle: "italic" },
    { tag: [tags.strong], fontWeight: "bold" },
    { tag: [tags.invalid], color: c.invalid }
  ])
}

/** Editor colors from the terminal theme. Selection and cursor are the host's, never the library default. */
function viewTheme(theme: EditorTheme, settings: EditorSettings): Extension {
  const c = chromeColors(theme)
  const selection = { background: `${c.selection} !important` }
  return [
    EditorView.theme(
      {
        "&": { height: "100%", color: c.foreground, backgroundColor: c.background, fontSize: `${fontSize(theme, settings)}px` },
        ".cm-scroller": { fontFamily: fontFamily(theme, settings), lineHeight: "1.5" },
        ".cm-content": { caretColor: c.cursor },
        ".cm-cursor, .cm-dropCursor": { borderLeftColor: c.cursor, borderLeftWidth: "2px" },
        ".cm-selectionBackground, &.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-content ::selection": selection,
        ".cm-activeLine": { backgroundColor: c.line },
        ".cm-activeLineGutter": { backgroundColor: c.line, color: c.gutterActive },
        ".cm-gutters": { backgroundColor: c.background, color: c.gutter, border: "none" },
        ".cm-lineNumbers .cm-gutterElement": { padding: "0 10px 0 12px" },
        ".cm-foldGutter .cm-gutterElement": { color: c.faint },
        "&.cm-focused": { outline: "none" },
        ".cm-matchingBracket, &.cm-focused .cm-matchingBracket": { backgroundColor: c.match, outline: `1px solid ${c.matchStrong}` },
        ".cm-nonmatchingBracket": { color: c.removed },
        ".cm-selectionMatch": { backgroundColor: c.match },
        ".cm-searchMatch": { backgroundColor: c.match, outline: `1px solid ${c.matchStrong}` },
        ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: c.matchStrong },
        ".cm-panels": { backgroundColor: c.statusBackground, color: c.foreground, borderColor: c.border },
        ".cm-panels.cm-panels-top": { borderBottom: `1px solid ${c.border}` },
        ".cm-textfield": { backgroundColor: c.background, color: c.foreground, border: `1px solid ${c.border}`, borderRadius: "4px" },
        ".cm-textfield:focus": { outline: `1px solid ${c.accent}` },
        ".cm-button": { backgroundImage: "none", backgroundColor: c.background, color: c.foreground, border: `1px solid ${c.border}`, borderRadius: "4px" },
        ".cm-panel input[type=checkbox]": { accentColor: c.accent },
        ".cm-tooltip": { backgroundColor: c.statusBackground, color: c.foreground, border: `1px solid ${c.border}` },
        // Merge view (diff mode).
        ".cm-changedLine, .cm-insertedLine": { backgroundColor: `${c.addedBand} !important` },
        ".cm-deletedChunk, .cm-deletedLine": { backgroundColor: `${c.removedBand} !important` },
        ".cm-changedText, .cm-insertedLine .cm-changedText": { background: `${c.addedText} !important` },
        ".cm-deletedChunk .cm-deletedText, .cm-deletedLine .cm-changedText": { background: `${c.removedText} !important` },
        ".cm-changeGutter": { width: "3px", paddingLeft: "0" },
        ".cm-deletedLineGutter": { background: c.removed },
        ".cm-insertedLineGutter, .cm-changedLineGutter": { background: c.added },
        ".cm-collapsedLines": { color: c.muted, background: c.statusBackground },
        ".cm-mergeSpacer": { backgroundColor: c.statusBackground }
      },
      { dark: theme.appearance === "dark" }
    ),
    syntaxHighlighting(highlightStyle(theme))
  ]
}

/** The original side of a side-by-side diff: its changed lines are removals. Theme scoping cannot see the `.cm-merge-a` wrapper, so side A gets its own rules. */
function originalSideTheme(theme: EditorTheme): Extension {
  const c = chromeColors(theme)
  return Prec.highest(
    EditorView.theme({
      ".cm-changedLine": { backgroundColor: `${c.removedBand} !important` },
      ".cm-changedText": { background: `${c.removedText} !important` },
      ".cm-changedLineGutter": { background: c.removed }
    })
  )
}

const settingsExtension = (s: EditorSettings): Extension => [
  s.lineNumbers ? [lineNumbers(), foldGutter({ openText: "⌄", closedText: "›" })] : [],
  s.wordWrap ? EditorView.lineWrapping : [],
  EditorState.tabSize.of(s.tabSize),
  indentUnit.of(" ".repeat(s.tabSize))
]

const readOnlyExtension = (ro: boolean): Extension => [EditorState.readOnly.of(ro), EditorView.editable.of(!ro)]

export function createCodeMirrorAdapter(): EditorAdapter {
  let view: EditorView | null = null
  let merge: MergeView | null = null
  let host: HTMLElement | null = null
  let diffOptions: DiffMountOptions | null = null
  let mode: "doc" | "diff" | null = null
  const language = new Compartment()
  const appearance = new Compartment()
  const prefs = new Compartment()
  const readOnly = new Compartment()

  const base = (o: { language: string; theme: EditorTheme; settings: EditorSettings }): Extension => [
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    drawSelection(),
    dropCursor(),
    rectangularSelection(),
    indentOnInput(),
    bracketMatching(),
    highlightSelectionMatches(),
    language.of(languageExtension(o.language)),
    appearance.of(viewTheme(o.theme, o.settings)),
    prefs.of(settingsExtension(o.settings))
  ]

  function destroy() {
    view?.destroy()
    merge?.destroy()
    view = null
    merge = null
    if (host) for (const c of [...host.children]) if (!c.classList.contains("cmux-empty")) c.remove()
  }

  function mountMerge() {
    const o = diffOptions!
    destroy()
    const shared = [...base(o), readOnlyExtension(true)]
    if (o.layout === "sideBySide") {
      merge = new MergeView({
        a: { doc: o.original, extensions: [...shared, originalSideTheme(o.theme)] },
        b: { doc: o.modified, extensions: shared },
        parent: host!,
        gutter: true,
        collapseUnchanged: { margin: 3, minSize: 6 }
      })
      merge.dom.style.height = "100%"
      merge.dom.style.overflow = "auto"
    } else {
      view = new EditorView({
        parent: host!,
        state: EditorState.create({ doc: o.modified, extensions: [...shared, highlightActiveLine(), unifiedMergeView({ original: o.original, mergeControls: false, gutter: true, collapseUnchanged: { margin: 3, minSize: 6 } })] })
      })
    }
  }

  return {
    name: "CodeMirror",
    capabilities: ["diff", "readOnly", "multiCursor"],
    mountDoc(el: HTMLElement, o: DocMountOptions) {
      host = el
      mode = "doc"
      destroy()
      const report = EditorView.updateListener.of((u) => {
        if (u.docChanged && !u.transactions.some((tr) => tr.annotation(fromHost))) o.onChange(u.state.doc.toString())
        if (u.selectionSet || u.docChanged) {
          const sel = u.state.selection.main
          const line = u.state.doc.lineAt(sel.head)
          o.onSelection({ line: line.number, column: sel.head - line.from + 1, length: Math.abs(sel.to - sel.from) })
        }
      })
      view = new EditorView({
        parent: el,
        state: EditorState.create({
          doc: o.text,
          extensions: [
            ...base(o),
            history(),
            closeBrackets(),
            highlightActiveLine(),
            readOnly.of(readOnlyExtension(o.readOnly)),
            keymap.of([{ key: "Mod-s", preventDefault: true, run: () => (o.onSave(), true) }, ...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, indentWithTab]),
            report
          ]
        })
      })
      const sel = view.state.selection.main
      o.onSelection({ line: 1, column: sel.head + 1, length: 0 })
    },
    setView(text: string, edits: TextEdit[]) {
      if (!view) return
      // `edits` apply in order, each against the previous result: one transaction each keeps that meaning.
      for (const e of edits) view.dispatch({ changes: { from: e.from, to: e.to, insert: e.text }, annotations: [fromHost.of(true)] })
      if (view.state.doc.toString() !== text) view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, annotations: [fromHost.of(true)] })
    },
    setReadOnly(ro: boolean) {
      view?.dispatch({ effects: readOnly.reconfigure(readOnlyExtension(ro)) })
    },
    setLanguage(id: string) {
      view?.dispatch({ effects: language.reconfigure(languageExtension(id)) })
    },
    setAppearance(theme: EditorTheme, settings: EditorSettings) {
      if (mode === "diff" && diffOptions) {
        diffOptions = { ...diffOptions, theme, settings }
        mountMerge()
        return
      }
      view?.dispatch({ effects: [appearance.reconfigure(viewTheme(theme, settings)), prefs.reconfigure(settingsExtension(settings))] })
    },
    mountDiff(el: HTMLElement, o: DiffMountOptions) {
      host = el
      mode = "diff"
      diffOptions = o
      mountMerge()
    },
    setDiffLayout(layout) {
      if (!diffOptions || diffOptions.layout === layout) return
      diffOptions = { ...diffOptions, layout }
      mountMerge()
    },
    focus() {
      ;(view ?? merge?.b)?.focus()
    },
    destroy
  }
}
