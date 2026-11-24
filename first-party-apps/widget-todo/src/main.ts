// To Do: a to-do list widget in the shape of Apple's Reminders widget. A big count of what is left,
// the list's name in the list's color, then rows with round checkboxes. Click a row to check it off:
// the circle fills, the text strikes through and the row slides out of the list (the SDK's RowList
// with `done` and `check`; the host animates it). Type in "New item" and press Return to add one.
// Small shows the count and the first items; medium a list; large a longer list with the done items
// folded into one "Completed" row.
//
// It imports nothing but the public SDK. The list is kept in the app's storage, one key per item, so
// it survives a restart and every placed tile shows the same list (store.ts). How the copies on two
// devices merge is in model.ts. A render that throws keeps its last good scene on the tile (marked
// stale by the host's apps-widget-health) and is mounted again; nothing here catches that.

import { Button, cmux, computed, HStack, Icon, RowList, signal, Spacer, Text, TextField, VStack, WIDGET_INSET, WIDGET_TYPE, WidgetFrame, type ListItem, type View } from "cmux-extension-sdk"
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

/** Reminders' list colors. The theme's accent is the text color by default, so the list's color is a hex. */
export const COLORS = {
  red: "#FF3B30",
  orange: "#FF9500",
  yellow: "#FFCC00",
  green: "#34C759",
  blue: "#007AFF",
  purple: "#AF52DE",
  brown: "#A2845E"
} as const

/** The list a tile draws: the stored one, or a fixed sample for the Add Widget preview. */
interface Source {
  items(): ReadonlyMap<string, Item>
  loaded(): boolean
  problem(): string | null
  add(text: string): void
  toggle(id: string): void
  remove(id: string): void
  clearCompleted(): void
}

const stored: Source = {
  items: store.items,
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
  return { items: () => items, loaded: () => true, problem: () => null, add: none, toggle: none, remove: none, clearCompleted: none }
}

function setting(ctx: WidgetContext, key: string): string {
  const own = ctx.settings?.[key]
  if (typeof own === "string" && own.trim()) return own.trim()
  const app = cmux.app.settings()[key]
  return typeof app === "string" ? app.trim() : ""
}

const listName = (ctx: WidgetContext) => setting(ctx, "title") || t("title", "To Do")

/** The list's color: a named Reminders color, or a hex the person typed; blue otherwise. */
export function listColor(ctx: WidgetContext): string {
  const value = setting(ctx, "color")
  if (/^#[0-9a-f]{6}$/i.test(value)) return value.toUpperCase()
  return COLORS[value.toLowerCase() as keyof typeof COLORS] ?? COLORS.blue
}

/** The rows: a round checkbox in the list's color, the item's text struck through once done. */
function rows(source: Source, list: () => readonly Item[], tint: string, max: number): View {
  const items = (): ListItem[] =>
    list().map((item) => {
      const label = item.done ? t("row.uncheck", "Mark as not done") : t("row.check", "Mark as done")
      return {
        id: item.id,
        title: item.text,
        done: item.done,
        check: true,
        tint,
        help: label,
        onTap: () => source.toggle(item.id),
        menu: () => [Button(label, () => source.toggle(item.id)), Button(t("row.delete", "Delete"), () => source.remove(item.id)).destructive()]
      }
    })
  return RowList(items, { max, spacing: 8 })
}

/** "New item": type and press Return to add to the end of the list. */
function newItemField(source: Source, tint: string): View {
  const [draft, setDraft] = signal("")
  const submit = (text: string) => {
    const value = cleanText(text)
    setDraft("")
    if (value) source.add(value)
  }
  return HStack({ spacing: 8 }, [
    Icon("action.add").size(WIDGET_TYPE.body + 6).color(tint),
    TextField(draft, { placeholder: t("new.placeholder", "New item"), onEdit: setDraft, onSubmit: submit }).font(WIDGET_TYPE.body)
  ])
}

function header(ctx: WidgetContext, size: Size, tint: string, remaining: () => number): View {
  const count = Text(remaining)
    .font(size === "small" ? 28 : WIDGET_TYPE.bigNumber)
    .weight("semibold")
    .lineLimit(1)
    .contentTransition("numericText")
  const name = Text(() => listName(ctx)).font(size === "small" ? WIDGET_TYPE.label : WIDGET_TYPE.title).weight("semibold").color(tint).lineLimit(1)
  return VStack({ alignment: "leading", spacing: 0 }, [count, name])
}

const more = (count: () => number) => Text(() => t("more", "{count} more", { count: count() })).font(WIDGET_TYPE.caption).color("secondary")

/** The widget. */
export function renderTodo(context: WidgetContext = {}): View {
  const source = context.preview ? sample() : stored
  if (!context.preview) store.start()
  const size = normalizeSize(context.size)
  const place = context.place === "sidebar" ? "sidebar" : "newtab"
  const tint = listColor(context)
  const lists = computed(() => split(source.items().values()))
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
    source.problem() ? Text(() => t("problem", "Couldn't save: {message}", { message: source.problem() ?? "" })).font(WIDGET_TYPE.footnote).color(cmux.theme.warning).lineLimit(2) : null
  const nothing = () => (empty() ? Text(t("empty", "Nothing to do")).font(WIDGET_TYPE.body).color("secondary") : null)

  if (size === "small") {
    return WidgetFrame(
      [
        header(context, size, tint, remaining),
        rows(source, open, tint, ROWS.small),
        () => (hidden() > 0 ? more(hidden) : null),
        nothing,
        // Small has room to add only while the list is empty; with items it is a glance.
        () => (empty() ? newItemField(source, tint) : null),
        problem
      ],
      { place, spacing: 6 }
    )
  }

  if (size === "medium") {
    return HStack({ spacing: 14, alignment: "top" }, [
      VStack({ alignment: "leading", spacing: 4 }, [header(context, size, tint, remaining), () => (hidden() > 0 ? more(hidden) : null)]).frame({ width: 104, maxHeight: "infinity" }),
      VStack({ alignment: "leading", spacing: 8 }, [nothing, rows(source, open, tint, ROWS.medium), newItemField(source, tint), problem]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
    ])
      .padding(WIDGET_INSET[place])
      .frame({ maxWidth: "infinity", maxHeight: "infinity" })
  }

  // Large: the list, "New item", then the done items folded into one row that opens them.
  const done = computed(() => lists().done)
  const shownDone = computed(() => done().slice(0, doneRows()))
  return WidgetFrame(
    [
      header(context, size, tint, remaining),
      VStack({ alignment: "leading", spacing: 8 }, [nothing, rows(source, open, tint, ROWS.large), () => (hidden() > 0 ? more(hidden) : null), newItemField(source, tint)]),
      () =>
        done().length > 0
          ? VStack({ alignment: "leading", spacing: 8 }, [
              HStack({ spacing: 6 }, [
                Icon(() => (showDone() ? "disclosure.expanded" : "disclosure.collapsed"))
                  .size(WIDGET_TYPE.caption)
                  .color("secondary"),
                Text(() => t("completed", "{count} Completed", { count: done().length }))
                  .font(WIDGET_TYPE.caption)
                  .color("secondary"),
                Spacer(),
                () =>
                  showDone()
                    ? Button(t("clear", "Clear"), () => {
                        source.clearCompleted()
                        setShowDone(false)
                      }).font(WIDGET_TYPE.caption)
                    : null
              ])
                .cursor("pointer")
                .onTap(() => setShowDone((v) => !v)),
              rows(source, shownDone, tint, 2)
            ])
          : null,
      problem
    ],
    { place, spacing: 10 }
  )
}
