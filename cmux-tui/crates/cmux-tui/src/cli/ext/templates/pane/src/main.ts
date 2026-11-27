// A pane, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships). Open it from
// the command palette by its title. Save this file while `cmux ext dev` runs: cmux redraws it.
// DESIGN.md says how a view should look; this one follows it: a title with its count, the list,
// and the loading, empty and failed states.
import { Badge, EmptyState, ForEach, HStack, Panel, pane, ProgressView, Row, Spacer, Text, VStack, workspaces } from "cmux-extension-sdk"

// The export cmux-app.json names for cmux.pane/1. `workspaces()` re-reads when cmux sends
// `workspace.changed` (scope workspace:read); nothing polls.
export const renderPane = pane(() => {
  const spaces = workspaces()
  const list = () => spaces() ?? []
  return VStack([
    Panel([
      HStack([Text("{{TITLE}}").font("title2").weight("semibold"), Spacer(), Badge(() => list().length, "secondary")]),
      VStack([
        ForEach({ items: list, key: (w) => w.id }, (w) =>
          Row({
            title: () => w().name,
            subtitle: () => (w().focused ? "Focused" : `Workspace ${w().index + 1}`),
            symbol: () => (w().focused ? "rectangle.inset.filled" : "rectangle"),
            selected: () => w().focused,
          })
        ),
      ]),
      () => {
        const error = spaces.error()
        if (error) return EmptyState({ title: "Can't read workspaces", message: error.message, symbol: "exclamationmark.triangle" })
        if (spaces.loading()) return ProgressView()
        return list().length === 0 ? EmptyState({ title: "No workspaces", symbol: "rectangle" }) : null
      },
    ]),
  ])
})
