// A tiny Today list: type a note, keep it local, clear it when standup is done.
const [notes, setNotes] = signal([]), [draft, setDraft] = signal("")
const [error, setError] = signal(null), [ready, setReady] = signal(false)
let loaded = false, changed = false, readFailed = false, writes = Promise.resolve()
const report = (e) => setError(e instanceof Error ? e.message : String(e))
const persist = (task) => { writes = writes.then(task).then(() => setError(null)).catch(report) }
function load() {
  if (loaded) return
  loaded = true
  cmux.storage.get("notes").then((saved) => {
    readFailed = false
    setError(null)
    if (!changed) setNotes(Array.isArray(saved) ? saved : [])
    setReady(true)
  }, (e) => { loaded = false; readFailed = true; report(e) })
}
function add(text, workspace) {
  if (!ready()) return cmux.toast({ title: "Still loading notes", tone: "warning" })
  const value = String(text || "").trim()
  if (!value) return
  changed = true
  const note = { id: `${Date.now()}-${notes().length}`, text: value, workspace: workspace || "Current workspace" }
  const next = [...notes(), note]
  setNotes(next)
  setDraft("")
  persist(() => cmux.storage.set("notes", next))
}
function clear() {
  if (!ready()) return cmux.toast({ title: "Still loading notes", tone: "warning" })
  changed = true
  setNotes([])
  persist(() => cmux.storage.delete("notes"))
}
function renderStandup() {
  const workspaces = cmux.live("workspace.list", {})
  const current = computed(() => (workspaces() || []).find((workspace) => workspace.focused)?.name)
  load()
  return VStack({ spacing: 2 }, [
    () => ready() ? TextField(draft, { placeholder: "What did you do?", onEdit: setDraft, onSubmit: (text) => add(text, current()) }) : Text("Loading notes…").color("secondary"),
    () => ready() ? HStack([Button("Add", () => add(draft(), current())), Button("Clear", clear)]) : null,
    ForEach({ items: notes, key: (note) => note.id }, (note) => Row({ title: () => note().text, subtitle: () => note().workspace, symbol: "checkmark" })),
    () => error() ? VStack({ spacing: 1 }, [EmptyState({ title: readFailed ? "Cannot load notes" : "Cannot save notes", message: error(), symbol: "exclamationmark.triangle" }), () => readFailed ? Button("Retry", () => { setError(null); load() }) : null]) : notes().length ? null : EmptyState({ title: "No notes yet", message: "Your local standup list appears here.", symbol: "checklist" })
  ])
}
globalThis.__cmuxAppExports = { renderStandup }
