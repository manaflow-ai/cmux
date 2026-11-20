// To-do widget: your to-do list as a card you add to the sidebar, in the three sizes system widgets
// come in. It imports nothing but the public SDK.
// - Small: how many are left and the first three.
// - Medium: the first four, and a field to add one.
// - Large: up to ten, the field, and the ones you ticked with a button to clear them.
// - Click an item's circle to tick it, click again to untick it. Right-click an item to edit,
//   remove or move it to the top; right-click the card to change its size.
// - The list is kept with storage:local, so it survives a reload or a restart, and every window
//   shows the same one. A change shows at once and saves behind it.

import { Button, cmux, computed, ForEach, HStack, Icon, Menu, Panel, signal, Spacer, Text, TextField, VStack, type View } from "cmux-extension-sdk"

export type Size = "small" | "medium" | "large"
export const SIZES: Size[] = ["small", "medium", "large"]
export interface Item { id: string; text: string; done: boolean }

const KEY = "items"
const SHOWN: Record<Size, number> = { small: 3, medium: 4, large: 10 }
const MAX_TEXT = 200

export function sizeOf(setting: unknown): Size {
  return SIZES.includes(setting as Size) ? (setting as Size) : "medium"
}

/** What a size shows: the open items first, in the person's order, then (large only) the ticked ones. */
export function visible(items: Item[], size: Size): { open: Item[]; done: Item[]; left: number; more: number } {
  const open = items.filter((i) => !i.done)
  const done = items.filter((i) => i.done)
  const shown = open.slice(0, SHOWN[size])
  const room = size === "large" ? Math.max(0, SHOWN.large - shown.length) : 0
  return { open: shown, done: done.slice(0, room), left: open.length, more: open.length - shown.length }
}

/** Keeps only well-formed items from storage (an older or hand-edited copy may hold anything). */
export function parse(saved: unknown): Item[] {
  if (!Array.isArray(saved)) return []
  return saved
    .filter((i): i is Item => !!i && typeof i.id === "string" && typeof i.text === "string")
    .map((i) => ({ id: i.id, text: i.text.slice(0, MAX_TEXT), done: i.done === true }))
}

const [items, setItems] = signal<Item[] | null>(null)
const [problem, setProblem] = signal<string | null>(null)
const [editing, setEditing] = signal<string | null>(null)
let loading = false
let nextId = 0

function newId(): string {
  nextId += 1
  return `${Date.now().toString(36)}-${nextId}`
}

function ensure() {
  if (items() !== null || loading) return
  loading = true
  cmux.storage.get<Item[]>(KEY).then(
    (saved) => {
      loading = false
      // An item added while this read was out wins over the saved copy only if nothing was saved.
      if (items() === null) setItems(parse(saved))
    },
    (error: unknown) => {
      loading = false
      if (items() === null) setItems([])
      setProblem(error instanceof Error ? error.message : String(error))
    }
  )
}

/** Changes the list here at once, then saves it. */
export function change(edit: (list: Item[]) => Item[]) {
  const next = edit(items() ?? [])
  setItems(next)
  const saved = next.length ? cmux.storage.set(KEY, next) : cmux.storage.delete(KEY)
  saved.then(
    () => setProblem(null),
    (error: unknown) => setProblem(error instanceof Error ? error.message : String(error))
  )
}

const add = (text: string) => {
  const value = text.trim().slice(0, MAX_TEXT)
  if (value) change((list) => [...list, { id: newId(), text: value, done: false }])
}
const toggle = (id: string) => change((list) => list.map((i) => (i.id === id ? { ...i, done: !i.done } : i)))
const remove = (id: string) => change((list) => list.filter((i) => i.id !== id))
const toTop = (id: string) =>
  change((list) => {
    const hit = list.find((i) => i.id === id)
    return hit ? [hit, ...list.filter((i) => i.id !== id)] : list
  })
const rename = (id: string, text: string) => {
  const value = text.trim().slice(0, MAX_TEXT)
  setEditing(null)
  if (value) change((list) => list.map((i) => (i.id === id ? { ...i, text: value } : i)))
}
const clearDone = () => change((list) => list.filter((i) => !i.done))

function sizeMenu(current: () => Size): View {
  const pick = (size: Size, title: string) =>
    Button(current() === size ? `✓ ${title}` : title, () => void cmux.app.settings.set({ size }).catch(() => undefined))
  return Menu("Size", [pick("small", "Small"), pick("medium", "Medium"), pick("large", "Large")])
}

const secondary = cmux.theme.text.secondary

function line(item: () => Item, compact: () => boolean): View {
  return HStack({ spacing: 8 }, [
    Icon(() => (item().done ? "checkmark.circle.fill" : "circle"))
      .font(() => (compact() ? "caption" : "body"))
      .color(() => (item().done ? cmux.theme.accent : cmux.theme.text.tertiary))
      .onTap(() => toggle(item().id))
      .help(() => (item().done ? "Untick" : "Tick")),
    () =>
      editing() === item().id
        ? TextField(item().text, { placeholder: "To-do", autofocus: true, onSubmit: (text: string) => rename(item().id, text), onCancel: () => setEditing(null) })
        : Text(() => item().text)
            .font(() => (compact() ? "caption" : "subheadline"))
            .lineLimit(1)
            .color(() => (item().done ? secondary : cmux.theme.text.primary)),
    Spacer()
  ])
    .opacity(() => (item().done ? 0.6 : 1))
    .contextMenu([
      Button("Edit", () => setEditing(item().id)),
      Button("Move to top", () => toTop(item().id)),
      Button("Remove", () => remove(item().id)).destructive()
    ])
}

export function renderTodo(): View {
  ensure()
  const size = computed(() => sizeOf(cmux.app.settings().size))
  const shown = computed(() => visible(items() ?? [], size()))
  const [draft, setDraft] = signal("")
  const submit = (text: string) => {
    setDraft("")
    add(text)
  }
  return Panel({ style: "card", spacing: 8 }, [
    HStack({ spacing: 6 }, [
      Icon("checklist").color(cmux.theme.accent),
      Text("To-do").font("headline").color(cmux.theme.accent),
      Spacer(),
      Text(() => String(shown().left)).font(() => (size() === "small" ? "title" : "title3")).weight("semibold")
    ]),
    ForEach({ items: () => shown().open, key: (i) => i.id }, (i) => line(i, () => size() === "small")),
    () => (items() !== null && shown().left === 0 && shown().done.length === 0 ? Text("Nothing to do").font("subheadline").color(secondary) : null),
    () => (shown().more > 0 ? Text(() => `${shown().more} more`).font("caption").color(secondary) : null),
    () => (size() === "small" ? null : TextField(draft, { placeholder: "New to-do", onEdit: setDraft, onSubmit: submit })),
    () =>
      shown().done.length
        ? VStack({ spacing: 6 }, [
            HStack({ spacing: 6 }, [Text("Done").font("caption").weight("semibold").color(secondary), Spacer(), Button("Clear", clearDone)]),
            ForEach({ items: () => shown().done, key: (i) => i.id }, (i) => line(i, () => false))
          ])
        : null,
    () => (problem() ? Text(() => `Couldn't save: ${problem()}`).font("caption").color(cmux.theme.warning) : null)
  ]).contextMenu(() => [sizeMenu(size), ...((items() ?? []).some((i) => i.done) ? [Button("Clear ticked", clearDone)] : [])])
}
