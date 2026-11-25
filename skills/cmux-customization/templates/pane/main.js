// A pane: the customize app's page, opened as a tab with "Open My views" in the Command
// Palette (no scope needed), `cmux action run app.open --app local/customize`, or the sidebar button below
// (which needs actions:run). The checklist is kept with storage:local when it is on, and
// lives only until the app reloads or its last view closes when it is off. Both are in Settings > Apps > My views.

const [items, setItems] = signal([]) // [{ id, text, done }]
const [draft, setDraft] = signal("")
let saving = true // false once a read or save is refused (storage:local is off)
let loaded = false

// Read the saved list the first time a view renders (a script makes no calls before that).
function load() {
  if (loaded) return
  loaded = true
  cmux.storage.get("items").then(
    // Items added before the read finished stay, after the saved ones, and are saved too.
    (saved) => {
      if (!Array.isArray(saved)) return
      const added = items().filter((x) => !saved.some((s) => s.id === x.id))
      added.length ? save([...saved, ...added]) : setItems(saved)
    },
    () => (saving = false)
  )
}

// Writes run one after another: the host may finish two calls in any order, and an older list
// landing last would drop the newer item.
let writing = Promise.resolve()
function save(next) {
  setItems(next)
  if (saving) writing = writing.then(() => cmux.storage.set("items", next)).catch(() => (saving = false))
}

function add(text) {
  const trimmed = String(text || "").trim()
  if (!trimmed) return
  save([...items(), { id: `${Date.now()}-${items().length}`, text: trimmed, done: false }])
  setDraft("")
}

const left = computed(() => items().filter((i) => !i.done).length)

function renderPane() {
  load()
  return VStack({ spacing: 8 }, [
    Panel({ title: "Scratchpad", style: "card" }, [
      TextField(draft, { placeholder: "Add an item and press Return", onEdit: setDraft, onSubmit: add }),
      ForEach({ items, key: (i) => i.id }, (i) =>
        Toggle(() => i().done, {
          label: () => i().text,
          onChange: (on) => save(items().map((x) => (x.id === i().id ? { ...x, done: on } : x)))
        })
      ),
      () => (items().length === 0 ? EmptyState({ title: "Nothing here yet", symbol: "checklist" }) : null),
      HStack([
        Text(() => `${left()} left`).color(cmux.theme.text.secondary),
        Spacer(),
        Button("Clear done", () => save(items().filter((i) => !i.done)))
      ])
    ])
  ])
}

function renderOpener() {
  load()
  return Row({ title: () => `Scratchpad · ${left()} left`, symbol: "checklist" }).onTap(() =>
    cmux.actions.run("app.open", { app: "local/customize" }).catch((e) =>
      cmux.toast({ title: "Open it from the palette: Open My views", message: e instanceof Error ? e.message : String(e), tone: "warning" })
    )
  )
}

globalThis.__cmuxAppExports = { renderPane, renderOpener }
