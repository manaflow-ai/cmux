// The editor pane controller (shared by the editor apps; identical copies):
// receives init and props over the bridge, opens the document through the
// proposed `document.*` ops, runs the document state machine and drives the
// editor library through an EditorAdapter. Implements `cmux.editor/1`.

import type { DocumentChangedEvent, DocumentConflictEvent, DocumentOpenResult, DocumentReadResult, DocRevision } from "../interfaces/document.ts"
import { DEFAULT_EDITOR_SETTINGS, type DiffSideInput, type EditorProps, type EditorSettings, type EditorStateName, type EditorTheme } from "../interfaces/editor.ts"
import { setLanguage, t } from "../l10n.ts"
import type { EditorAdapter, Selection } from "./adapter.ts"
import { BridgeCallError, type Bridge, type InitMessage } from "./bridge.ts"
import { createChrome, normalizeVariant, type Chrome, type EditorVariant } from "./chrome.ts"
import { initialDocState, reduce, reopened, type DocEffect, type DocEvent, type DocState } from "./doc-session.ts"
import { languageForPath } from "./languages.ts"
import { applyCssVariables, FALLBACK_THEME } from "./theme.ts"

export function editorSettings(raw: Record<string, unknown>): EditorSettings {
  const s = { ...DEFAULT_EDITOR_SETTINGS }
  if (typeof raw.variant === "string") s.variant = raw.variant
  if (typeof raw.fontFamily === "string") s.fontFamily = raw.fontFamily
  if (typeof raw.fontSize === "number") s.fontSize = raw.fontSize
  if (typeof raw.minimap === "boolean") s.minimap = raw.minimap
  if (typeof raw.wordWrap === "boolean") s.wordWrap = raw.wordWrap
  if (typeof raw.lineNumbers === "boolean") s.lineNumbers = raw.lineNumbers
  if (typeof raw.tabSize === "number" && raw.tabSize >= 1 && raw.tabSize <= 16) s.tabSize = raw.tabSize
  if (raw.renderWhitespace === "boundary" || raw.renderWhitespace === "all") s.renderWhitespace = raw.renderWhitespace
  return s
}

const errCode = (e: unknown) => (e instanceof BridgeCallError ? e.code : "error")
const errMessage = (e: unknown) => (e instanceof Error ? e.message : String(e))

export interface Controller {
  state(): DocState
  dispatch(ev: DocEvent): void
  runCommand(command: string, args: Record<string, unknown>): Promise<unknown>
}

export function startEditor(adapter: EditorAdapter, bridge: Bridge, root: HTMLElement, doc: Document): Controller {
  let init: InitMessage | null = null
  let props: EditorProps = {}
  let theme: EditorTheme = FALLBACK_THEME
  let settings: EditorSettings = DEFAULT_EDITOR_SETTINGS
  let variant: EditorVariant = "statusLine"
  let state: DocState = initialDocState()
  let selection: Selection | null = null
  let mounted: "doc" | "diff" | null = null
  let language = "plaintext"
  let diffName = ""
  let unsubscribe: Array<() => void> = []
  let lastEmitted = ""
  let chrome: Chrome

  const ownOrigin = () => `view:${init?.pane ?? ""}`
  const docHandle = () => props.doc ?? ""

  const render = () =>
    chrome.update(variant, props.chrome ?? "full", mounted === "doc" ? state : null, {
      name: mounted === "diff" ? diffName : (state.info?.name ?? ""),
      language,
      selection: mounted === "doc" ? selection : null,
      encoding: mounted === "doc" ? (state.info?.encoding ?? "") : "",
      lineEnding: state.info?.lineEnding ?? "lf",
      library: adapter.name
    })

  function emitState() {
    const name: EditorStateName = state.phase === "ready" ? (state.dirty ? "dirty" : "clean") : state.phase
    const key = `${name}:${state.dirty}`
    if (key === lastEmitted) return
    lastEmitted = key
    bridge.emit({ type: "stateChanged", state: name, dirty: state.dirty })
  }

  function dispatch(ev: DocEvent) {
    const r = reduce(state, ev)
    apply(r.state, r.effects)
  }

  function apply(next: DocState, effects: DocEffect[]) {
    const wasReadOnly = state.readOnly || state.readOnlyProp
    state = next
    if (mounted === "doc" && wasReadOnly !== (state.readOnly || state.readOnlyProp)) adapter.setReadOnly(state.readOnly || state.readOnlyProp)
    for (const e of effects) run(e)
    render()
    emitState()
  }

  function run(e: DocEffect) {
    const docId = docHandle()
    switch (e.type) {
      case "setView":
        if (mounted === "doc") adapter.setView(e.text, e.edits)
        return
      case "sendEdit":
        bridge.call<{ revision: DocRevision; dirty: boolean }>("document.edit", { doc: docId, base_revision: e.base, edits: e.edits }).then(
          (r) => dispatch({ type: "editAcked", id: e.id, revision: r.revision, dirty: r.dirty }),
          (err) => dispatch({ type: "editFailed", id: e.id, code: errCode(err), message: errMessage(err) })
        )
        return
      case "save":
        bridge.call<{ revision: DocRevision }>("document.save", { doc: docId, revision: e.revision, overwrite_disk: e.overwriteDisk || undefined }).then(
          (r) => dispatch({ type: "saved", revision: r.revision }),
          (err) => {
            const details = err instanceof BridgeCallError ? (err.details as { disk_revision?: DocRevision } | undefined) : undefined
            dispatch({ type: "saveFailed", code: errCode(err), message: errMessage(err), diskRevision: details?.disk_revision })
          }
        )
        return
      case "revert":
      case "resync":
        bridge.call<DocumentOpenResult>(e.type === "revert" ? "document.revert" : "document.open", { doc: docId }).then(
          (r) => {
            const out = reopened(state, r.info, r.text)
            apply(out.state, out.effects)
          },
          (err) => dispatch({ type: "openFailed", code: errCode(err), message: errMessage(err) })
        )
        return
    }
  }

  function showError(err: unknown, op: string) {
    const code = errCode(err)
    if (code === "operation.unsupported" || code === "scope.missing") chrome.showEmpty(t("error.missing", "{op} is not available yet.", { op }), adapter.name)
    else chrome.showEmpty(t("error.open", "Cannot open this document"), errMessage(err))
  }

  async function openDoc() {
    const handle = docHandle()
    for (const off of unsubscribe) off()
    unsubscribe = []
    state = initialDocState()
    if (!handle) {
      chrome.showEmpty(t("empty.noDocument", "No document"))
      render()
      return
    }
    chrome.showEmpty(t("empty.loading", "Opening"))
    let r: DocumentOpenResult
    try {
      r = await bridge.call<DocumentOpenResult>("document.open", { doc: handle })
    } catch (err) {
      dispatch({ type: "openFailed", code: errCode(err), message: errMessage(err) })
      showError(err, "document.open")
      return
    }
    language = props.language ?? r.info.type.language ?? languageForPath(r.info.name)
    chrome.hideEmpty()
    const opts = {
      text: r.text,
      language,
      readOnly: r.info.readOnly || !!props.readOnly,
      theme,
      settings,
      onChange: (text: string) => dispatch({ type: "viewChanged", text }),
      onSelection: (sel: Selection) => {
        selection = sel
        render()
        bridge.emit({ type: "selectionChanged", line: sel.line, column: sel.column, selectionLength: sel.length })
      },
      onSave: () => dispatch({ type: "saveRequested" })
    }
    if (mounted) adapter.destroy()
    adapter.mountDoc(chrome.editorHost, opts)
    mounted = "doc"
    state = { ...state, viewText: r.text, readOnlyProp: !!props.readOnly }
    dispatch({ type: "opened", info: r.info, text: r.text })
    unsubscribe.push(
      bridge.on("document.changed", { doc: handle }, (p) => dispatch({ type: "remoteChanged", event: p as DocumentChangedEvent, ownOrigin: ownOrigin() })),
      bridge.on("document.conflict", { doc: handle }, (p) => {
        const c = p as DocumentConflictEvent
        dispatch({ type: "conflict", diskRevision: c.disk_revision, bufferRevision: c.buffer_revision })
      })
    )
  }

  async function readSide(side: DiffSideInput): Promise<string> {
    if ("text" in side) return side.text
    if ("diff" in side) return (await bridge.call<DocumentReadResult>("diff.file.read", { diff: side.diff, path: side.path, side: side.side })).text
    if (side.revision) return (await bridge.call<DocumentReadResult>("document.read", { doc: side.doc, revision: side.revision })).text
    return (await bridge.call<DocumentOpenResult>("document.open", { doc: side.doc })).text
  }

  async function openDiff() {
    const d = props.diff!
    diffName = d.path ?? ""
    language = props.language ?? languageForPath(d.path)
    chrome.showEmpty(t("diff.loading", "Loading diff"))
    render()
    let original: string
    let modified: string
    try {
      ;[original, modified] = await Promise.all([readSide(d.original), readSide(d.modified)])
    } catch (err) {
      showError(err, "diff" in d.original ? "diff.file.read" : "document.read")
      return
    }
    chrome.hideEmpty()
    if (mounted) adapter.destroy()
    adapter.mountDiff(chrome.editorHost, { original, modified, layout: d.layout, language, theme, settings })
    mounted = "diff"
    render()
  }

  const open = () => (props.diff ? openDiff() : openDoc())

  async function runCommand(command: string, args: Record<string, unknown>): Promise<unknown> {
    switch (command) {
      case "save":
        dispatch({ type: "saveRequested" })
        return { phase: state.phase }
      case "revert":
        if (state.revision) run({ type: "revert" })
        return null
      case "toggleReadOnly":
        props = { ...props, readOnly: !(props.readOnly ?? false) }
        dispatch({ type: "setReadOnly", readOnly: !!props.readOnly })
        return { readOnly: props.readOnly }
      case "focus":
        adapter.focus()
        return null
      default:
        throw new BridgeCallError("command.unknown", `${command} ${JSON.stringify(args)}`)
    }
  }

  function compare() {
    const c = state.conflict
    if (!c) return
    const handle = docHandle()
    const title = state.info?.name ?? ""
    bridge.emit({ type: "openDiff", base: { doc: handle, revision: c.diskRevision }, head: { doc: handle, revision: c.bufferRevision }, title })
    bridge.call("ui.open", { interface: "cmux.diff.renderer/1", props: { input: { kind: "documents", base: { doc: handle, revision: c.diskRevision }, head: { doc: handle, revision: c.bufferRevision }, title } } }).catch(() => undefined)
  }

  chrome = createChrome(doc, root, {
    save: () => dispatch({ type: "saveRequested" }),
    compare,
    resolve: (keep) => dispatch({ type: "resolve", keep }),
    retry: () => run({ type: "resync" })
  })

  bridge.handlers.init = (m) => {
    init = m
    setLanguage(m.locale)
    theme = m.theme ?? FALLBACK_THEME
    settings = editorSettings(m.settings ?? {})
    variant = normalizeVariant(settings.variant)
    props = m.props ?? {}
    doc.documentElement.dataset.appearance = theme.appearance
    applyCssVariables(doc.documentElement, theme, settings)
    open()
    bridge.emit({ type: "ready", capabilities: adapter.capabilities })
  }
  bridge.handlers.props = (p) => {
    const prev = props
    props = p
    if (p.doc !== prev.doc || !!p.diff !== !!prev.diff || JSON.stringify(p.diff?.original) !== JSON.stringify(prev.diff?.original) || JSON.stringify(p.diff?.modified) !== JSON.stringify(prev.diff?.modified)) {
      open()
      return
    }
    if (p.diff && p.diff.layout !== prev.diff?.layout) adapter.setDiffLayout(p.diff.layout)
    if (!!p.readOnly !== !!prev.readOnly) dispatch({ type: "setReadOnly", readOnly: !!p.readOnly })
    if (p.language && p.language !== prev.language) {
      language = p.language
      adapter.setLanguage(language)
    }
    render()
  }
  bridge.handlers.theme = (th) => {
    theme = th
    doc.documentElement.dataset.appearance = th.appearance
    applyCssVariables(doc.documentElement, theme, settings)
    adapter.setAppearance(theme, settings)
  }
  bridge.handlers.settings = (raw) => {
    settings = editorSettings(raw)
    variant = normalizeVariant(settings.variant)
    applyCssVariables(doc.documentElement, theme, settings)
    adapter.setAppearance(theme, settings)
    render()
  }
  bridge.handlers.command = (command, args) => runCommand(command, args)

  return { state: () => state, dispatch, runCommand }
}
