// Workspace notes: a short to-do list for the workspace you are in, in a sidebar section. Switch
// workspaces and the list switches with you. It imports nothing but the public SDK.
// - workspaces() says which workspace is focused; it re-reads when cmux sends workspace.changed.
// - Each workspace's list is kept with storage:local, under the workspace's id, so it survives a
//   reload or a restart. Every window shows the same list: they share the extension's one copy.
// - Type a note and press Return to add it; click a note to tick it; right-click to remove it or
//   clear the ticked ones.

import { Button, cmux, computed, EmptyState, ForEach, Row, signal, Text, TextField, VStack, workspaces, type View, type Workspace } from "cmux-extension-sdk"

export interface Note { id: string; text: string; done: boolean }

const key = (workspace: string) => `notes:${workspace}`
const [lists, setLists] = signal<Record<string, Note[]>>({})
const [problem, setProblem] = signal<string | null>(null)
const loading = new Set<string>()
let nextId = 0

function newId(): string {
  nextId += 1
  return `${Date.now().toString(36)}-${nextId}`
}

/** Reads a workspace's list once; later reads come from the shared copy. */
function ensure(workspace: string) {
  if (workspace in lists() || loading.has(workspace)) return
  loading.add(workspace)
  cmux.storage.get<Note[]>(key(workspace)).then(
    (saved) => {
      loading.delete(workspace)
      // A note added while this read was out wins over the empty saved list.
      if (!(workspace in lists())) setLists((all) => ({ ...all, [workspace]: Array.isArray(saved) ? saved : [] }))
    },
    (error: unknown) => {
      loading.delete(workspace)
      setProblem(error instanceof Error ? error.message : String(error))
    }
  )
}

/** Changes a workspace's list here at once, then saves it. */
export function change(workspace: string, edit: (notes: Note[]) => Note[]) {
  const next = edit(lists()[workspace] ?? [])
  setLists((all) => ({ ...all, [workspace]: next }))
  const saved = next.length ? cmux.storage.set(key(workspace), next) : cmux.storage.delete(key(workspace))
  saved.then(
    () => setProblem(null),
    (error: unknown) => setProblem(error instanceof Error ? error.message : String(error))
  )
}

export function renderNotes(): View {
  const spaces = workspaces()
  const current = computed<Workspace | undefined>(() => (spaces() ?? []).find((w) => w.focused))
  const notes = computed(() => {
    const w = current()
    if (!w) return []
    ensure(w.id)
    return lists()[w.id] ?? []
  })
  const [draft, setDraft] = signal("")
  const add = (text: string) => {
    const w = current()
    const value = text.trim()
    if (!w || !value) return
    setDraft("")
    change(w.id, (list) => [...list, { id: newId(), text: value, done: false }])
  }
  const toggle = (note: Note) => {
    const w = current()
    if (w) change(w.id, (list) => list.map((n) => (n.id === note.id ? { ...n, done: !n.done } : n)))
  }
  const remove = (note: Note) => {
    const w = current()
    if (w) change(w.id, (list) => list.filter((n) => n.id !== note.id))
  }
  const clearDone = () => {
    const w = current()
    if (w) change(w.id, (list) => list.filter((n) => !n.done))
  }
  return VStack({ spacing: 2 }, [
    () => (current() ? Text(() => `For ${current()!.name}`).font("caption").color(cmux.theme.text.secondary).lineLimit(1) : null),
    ForEach({ items: notes, key: (n) => n.id }, (n) =>
      Row({
        title: () => n().text,
        symbol: () => (n().done ? "checkmark.circle.fill" : "circle"),
        tint: () => (n().done ? cmux.theme.success : cmux.theme.text.secondary)
      })
        .opacity(() => (n().done ? 0.6 : 1))
        .onTap(() => toggle(n()))
        .contextMenu([Button("Remove", () => remove(n())), Button("Clear ticked notes", clearDone)])
    ),
    () => (current() ? TextField(draft, { placeholder: "Add a note for this workspace", onEdit: setDraft, onSubmit: add }) : null),
    () => (spaces.error() ? EmptyState({ title: "Can't read workspaces", message: spaces.error()!.message, symbol: "exclamationmark.triangle" }) : null),
    () => (problem() ? Text(() => `Couldn't save: ${problem()}`).font("caption").color(cmux.theme.warning) : null)
  ])
}
