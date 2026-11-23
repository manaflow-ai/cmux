// A sidebar section, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// Save this file while `cmux ext dev` runs: it rebuilds dist/main.js and cmux redraws the section.
// DESIGN.md says how a view should look; this one follows it: a lead line, then the list, every
// state drawn. Change the words and the data, keep the shape.
import { Button, cmux, computed, Divider, EmptyState, ForEach, HStack, Menu, Panel, ProgressView, Row, section, signal, Spacer, Text, VStack } from "cmux-extension-sdk"

type Task = { id: number; title: string; note: string; done: boolean }

// State lives in signals; a view that reads one redraws when it changes.
const [tasks, setTasks] = signal<Task[]>([
  { id: 1, title: "Review pull requests", note: "3 waiting on you", done: true },
  { id: 2, title: "Answer the design thread", note: "Since this morning", done: false },
  { id: 3, title: "Write the release notes", note: "Due Friday", done: false },
])
const done = computed(() => tasks().filter((t) => t.done).length)
const left = computed(() => tasks().length - done())
const flip = (id: number) => setTasks((list) => list.map((t) => (t.id === id ? { ...t, done: !t.done } : t)))

// The export cmux-app.json names for cmux.section/1.
export const renderSection = section(() =>
  VStack([
    Panel({ title: "{{TITLE}}" }, [
      // The lead line: what a glance should give, its detail under it, the rest in a menu.
      HStack([
        VStack({ alignment: "leading" }, [
          Text(() => (left() === 0 ? "All done" : `${left()} left today`)).font("headline"),
          Text(() => `${done()} of ${tasks().length} done`).font("caption").color("secondary"),
        ]),
        Spacer(),
        Menu("More", [
          Button("Clear done", () => setTasks((list) => list.filter((t) => !t.done))),
          Divider(),
          Button("Say hi", () => cmux.toast({ title: "Hi from {{TITLE}}", tone: "success" })),
        ]),
      ]),
      ProgressView(() => done() / Math.max(1, tasks().length)),
      // The list: one Row per thing, a symbol each, its one fact in the subtitle.
      VStack([
        ForEach({ items: tasks, key: (t) => t.id }, (t) =>
          Row({
            title: () => t().title,
            subtitle: () => t().note,
            symbol: () => (t().done ? "checkmark.circle.fill" : "circle"),
            tint: () => (t().done ? cmux.theme.success : cmux.theme.text.tertiary),
          }).onTap(() => flip(t().id))
        ),
        () => (tasks().length === 0 ? EmptyState({ title: "Nothing left", symbol: "checkmark.circle" }) : null),
      ]),
    ]),
  ])
)
