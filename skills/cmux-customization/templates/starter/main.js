// The customize app's script: a classic script, not a module (no import or export).
// The scene globals (VStack, Panel, Row, Button, Toggle, Text, signal, computed, cmux, ...)
// are already defined. cmux reloads this file every time it is saved.
// Show or hide this sidebar with Toggle Custom Sidebar (Cmd+Shift+P) or Ctrl+Opt+Cmd+B.

// State lives in signals; a view that reads one redraws when it changes.
const [tasks, setTasks] = signal([
  { id: 1, title: "Review pull requests", note: "3 waiting on you", done: true },
  { id: 2, title: "Answer the design thread", note: "Since this morning", done: false },
  { id: 3, title: "Write the release notes", note: "Due Friday", done: false }
])
const done = computed(() => tasks().filter((t) => t.done).length)
const left = computed(() => tasks().length - done())
const flip = (id) => setTasks((list) => list.map((t) => (t.id === id ? { ...t, done: !t.done } : t)))

// One render function per implementation in cmux-app.json (its "export"). The shape: one lead
// line, then rows with a symbol each, actions in a menu, every state drawn. Tones, never colors.
function renderSection() {
  return VStack([
    Panel({ title: "Today" }, [
      HStack([
        VStack({ alignment: "leading" }, [
          Text(() => (left() === 0 ? "All done" : `${left()} left today`)).font("headline"),
          Text(() => `${done()} of ${tasks().length} done`).font("caption").color("secondary")
        ]),
        Spacer(),
        Menu("More", [
          Button("Clear done", () => setTasks((list) => list.filter((t) => !t.done))),
          Divider(),
          Button("Say hi", () => cmux.toast({ title: "Hi from my section", tone: "success" }))
        ])
      ]),
      ProgressView(() => done() / Math.max(1, tasks().length)),
      VStack([
        ForEach({ items: tasks, key: (t) => t.id }, (t) =>
          Row({
            title: () => t().title,
            subtitle: () => t().note,
            symbol: () => (t().done ? "checkmark.circle.fill" : "circle"),
            tint: () => (t().done ? cmux.theme.success : cmux.theme.text.tertiary)
          }).onTap(() => flip(t().id))
        ),
        () => (tasks().length === 0 ? EmptyState({ title: "Nothing left", symbol: "checkmark.circle" }) : null)
      ])
    ]),
    Row({ title: "Edit main.js in the views folder from cmux customize paths", symbol: "pencil", tint: cmux.theme.text.secondary })
  ])
}

// Hand every render function to cmux, once, in one object.
globalThis.__cmuxAppExports = { renderSection }
