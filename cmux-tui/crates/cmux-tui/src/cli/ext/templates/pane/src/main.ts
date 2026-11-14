// A pane, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships). Open it from
// the command palette by its title. Save this file while `cmux ext dev` runs: cmux redraws it.
import { EmptyState, ForEach, pane, Row, VStack, workspaces } from "cmux-extension-sdk"

// The export cmux-app.json names for cmux.pane/1. `workspaces()` re-reads when cmux sends
// `workspace.changed` (scope workspace:read); nothing polls.
export const renderPane = pane(() => {
  const spaces = workspaces()
  return VStack({ spacing: 2 }, [
    ForEach({ items: () => spaces() ?? [], key: (w) => w.id }, (w) =>
      Row({ title: () => w().name, symbol: () => (w().focused ? "rectangle.inset.filled" : "rectangle") })
    ),
    () =>
      spaces.error()
        ? EmptyState({ title: "Can't read workspaces", message: spaces.error()!.message, symbol: "exclamationmark.triangle" })
        : null,
  ])
})
