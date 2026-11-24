// To Do: a to-do list widget in the shape of Apple's Reminders widget. A big count of what is left,
// the list's name in the accent color, then rows with round checkboxes. Click a row to check it off:
// the circle fills, the row fades, and a moment later it leaves the list. Type in "New item" and press
// Return to add one. Small shows the count and the first items; medium a list; large a longer list
// with the done items folded into one "Completed" row.
//
// It imports nothing but the public SDK. The list is kept in the app's storage, one key per item, so
// it survives a restart and every placed tile shows the same list (store.ts). How the copies on two
// devices merge is in model.ts.

import { Button, Circle, cmux, computed, Divider, ForEach, HStack, Icon, signal, Spacer, Text, TextField, VStack, type View } from "cmux-extension-sdk"
import { t } from "./l10n.ts"
import { cleanText, normalizeSize, ROWS, split, type Item, type Size } from "./model.ts"
import * as store from "./store.ts"

/** What cmux passes a widget render (`cmux.widget/1`). */
export interface WidgetContext {
  surface?: "widget"
  place?: "newtab" | "sidebar"
  size?: Size
  instance?: string
  settings?: Record<string, unknown>
  /** The Add Widget gallery's preview: show sample items and write nothing. */
  preview?: boolean
}

/** Apple's widget type scale (points) and margins, as the SDK's widget helpers use them. */
const TYPE = { bigNumber: 34, smallNumber: 28, title: 15, label: 13, body: 13, caption: 12, footnote: 11 } as const
const INSET = { newtab: 16, sidebar: 12 } as const

const accent = cmux.theme.accent

/** The list a tile draws: the stored one, or a fixed sample for the Add Widget preview. */
interface Source {
  items(): ReadonlyMap<string, Item>
  settling(): ReadonlySet<string>
  loaded(): boolean
  problem(): string | null
  add(text: string): void
  toggle(id: string): void
  remove(id: string): void
  clearCompleted(): void
}

const stored: Source = {
  items: store.items,
  settling: store.settling,
  loaded: store.loaded,
  problem: store.problem,
  add: (text) => void store.add(text),
  toggle: store.toggle,
  remove: store.remove,
  clearCompleted: store.clearCompleted
}

function sample(): Source {
  const at = 0
  const entry = (id: string, text: string, done = false): [string, Item] => [id, { id, text, done, created: at + id.charCodeAt(0), updated: at, by: "" }]
  const items = new Map([entry("a", t("sample.1", "Buy milk")), entry("b", t("sample.2", "Call the dentist")), entry("c", t("sample.3", "Water the plants")), entry("d", t("sample.4", "Book flights"), true)])
  const none = () => {}
  return { items: () => items, settling: () => new Set(), loaded: () => true, problem: () => null, add: none, toggle: none, remove: none, clearCompleted: none }
}

function listName(ctx: WidgetContext): string {
  const own = ctx.settings?.title
  if (typeof own === "string" && own.trim()) return own.trim()
  const app = cmux.app.settings().title
  if (typeof app === "string" && app.trim()) return app.trim()
  return t("title", "To Do")
}

/** Reminders' round checkbox, drawn with shapes so every renderer draws it the same: an empty ring, or a filled disc. */
function checkbox(done: () => boolean, size: Size): () => View {
  const side = size === "small" ? 15 : 19
  return () =>
    done()
      ? Circle().fill(accent).size(side)
      : Circle().stroke(cmux.theme.text.tertiary).strokeWidth(1.5).size(side)
}

/** One row: a round checkbox and the item's text. */
function row(source: Source, item: () => Item, size: Size): View {
  const settling = () => source.settling().has(item().id)
  const label = () => (item().done ? t("row.uncheck", "Mark as not done") : t("row.check", "Mark as done"))
  return HStack({ spacing: size === "small" ? 6 : 9 }, [
    checkbox(() => item().done, size),
    Text(() => item().text)
      .font(size === "small" ? TYPE.caption : TYPE.body)
      .color(() => (item().done && !settling() ? cmux.theme.text.secondary : cmux.theme.text.primary))
      .lineLimit(1),
    Spacer()
  ])
    .opacity(() => (settling() ? 0.45 : 1))
    .cursor("pointer")
    .help(label)
    .onTap(() => source.toggle(item().id))
    .contextMenu(() => [Button(label(), () => source.toggle(item().id)), Button(t("row.delete", "Delete"), () => source.remove(item().id)).destructive()])
}

/** A list of rows with Reminders' hairlines between them, inset to the text. */
function rows(source: Source, list: () => readonly Item[], size: Size): View {
  return ForEach({ items: list, key: (i) => i.id, spacing: size === "small" ? 3 : 0 }, (item, key) =>
    VStack({ spacing: 0 }, [
      () => (size !== "small" && list()[0]?.id !== key ? Divider().padding({ leading: 28 }) : null),
      size === "small" ? row(source, item, size) : row(source, item, size).paddingVertical(5)
    ])
  )
}

/** "New item": type and press Return to add to the end of the list. */
function newItemField(source: Source, size: Size): View {
  const [draft, setDraft] = signal("")
  const submit = (text: string) => {
    const value = cleanText(text)
    setDraft("")
    if (value) source.add(value)
  }
  const line = HStack({ spacing: size === "small" ? 6 : 9 }, [
    Icon("action.add").size(size === "small" ? 15 : 19).color(accent),
    TextField(draft, { placeholder: t("new.placeholder", "New item"), onEdit: setDraft, onSubmit: submit }).font(size === "small" ? TYPE.caption : TYPE.body)
  ])
  return size === "small" ? line : line.paddingVertical(5)
}

function header(ctx: WidgetContext, size: Size, remaining: () => number): View {
  const count = Text(remaining).font(size === "small" ? TYPE.smallNumber : TYPE.bigNumber).weight("semibold").lineLimit(1)
  const name = Text(() => listName(ctx)).font(size === "small" ? TYPE.label : TYPE.title).weight("semibold").color(accent).lineLimit(1)
  return VStack({ alignment: "leading", spacing: 0 }, [count, name])
}

const more = (count: () => number) => Text(() => t("more", "{count} more", { count: count() })).font(TYPE.caption).color(cmux.theme.text.secondary)

/** The widget. */
export function renderTodo(context: WidgetContext = {}): View {
  const source = context.preview ? sample() : stored
  if (!context.preview) store.start()
  const size = normalizeSize(context.size)
  const inset = context.place === "sidebar" ? INSET.sidebar : INSET.newtab
  const lists = computed(() => split(source.items().values(), source.settling()))
  // Large with Completed open shares its rows: up to two done ones, the open ones in the rest, and
  // in large the "N more" line under the open rows takes a row of its own.
  const [showDone, setShowDone] = signal(false)
  const doneRows = computed(() => (size === "large" && showDone() ? Math.min(2, lists().done.length) : 0))
  const openRows = () => {
    const rows = ROWS[size] - doneRows()
    return size === "large" && lists().open.length > rows ? rows - 1 : rows
  }
  const open = computed(() => lists().open.slice(0, openRows()))
  const hidden = computed(() => Math.max(0, lists().open.length - openRows()))
  const remaining = () => lists().remaining
  const empty = () => source.loaded() && lists().open.length === 0
  const problem = () =>
    source.problem() ? Text(() => t("problem", "Couldn't save: {message}", { message: source.problem() ?? "" })).font(TYPE.footnote).color(cmux.theme.warning).lineLimit(2) : null
  const nothing = () => (empty() ? Text(t("empty", "Nothing to do")).font(size === "small" ? TYPE.caption : TYPE.body).color(cmux.theme.text.secondary) : null)

  if (size === "small") {
    return VStack({ alignment: "leading", spacing: 6 }, [
      header(context, size, remaining),
      rows(source, open, size),
      () => (hidden() > 0 ? more(hidden) : null),
      nothing,
      // Small has room to add only while the list is empty; with items it is a glance.
      () => (empty() ? newItemField(source, size) : null),
      problem
    ])
      .padding(inset)
      .frame({ maxWidth: "infinity", maxHeight: "infinity" })
  }

  if (size === "medium") {
    return HStack({ spacing: 14 }, [
      VStack({ alignment: "leading", spacing: 4 }, [header(context, size, remaining), () => (hidden() > 0 ? more(hidden) : null)]).frame({ width: 104, maxHeight: "infinity" }),
      VStack({ alignment: "leading", spacing: 0 }, [nothing, rows(source, open, size), () => (open().length > 0 ? Divider().padding({ leading: 28 }) : null), newItemField(source, size), problem]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
    ]).padding(inset).frame({ maxWidth: "infinity", maxHeight: "infinity" })
  }

  // Large: the list, "New item", then the done items folded into one row that opens them.
  const done = computed(() => lists().done)
  const shownDone = computed(() => done().slice(0, doneRows()))
  return VStack({ alignment: "leading", spacing: 8 }, [
    header(context, size, remaining),
    Divider(),
    VStack({ alignment: "leading", spacing: 0 }, [
      nothing,
      rows(source, open, size),
      () => (hidden() > 0 ? more(hidden).padding({ leading: 28, top: 4, bottom: 4 }) : null),
      () => (open().length > 0 ? Divider().padding({ leading: 28 }) : null),
      newItemField(source, size)
    ]),
    () =>
      done().length > 0
        ? VStack({ alignment: "leading", spacing: 0 }, [
            HStack({ spacing: 6 }, [
              Icon(() => (showDone() ? "disclosure.expanded" : "disclosure.collapsed")).size(TYPE.caption).color(cmux.theme.text.secondary),
              Text(() => t("completed", "{count} Completed", { count: done().length })).font(TYPE.caption).color(cmux.theme.text.secondary),
              Spacer(),
              () => (showDone() ? Button(t("clear", "Clear"), () => {
                    source.clearCompleted()
                    setShowDone(false)
                  }).font(TYPE.caption) : null)
            ])
              .cursor("pointer")
              .onTap(() => setShowDone((v) => !v)),
            rows(source, shownDone, size)
          ])
        : null,
    problem
  ])
    .padding(inset)
    .frame({ maxWidth: "infinity", maxHeight: "infinity" })
}
