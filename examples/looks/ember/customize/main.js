// Ember's sidebar: a hover card laid out like a launcher's result row, and plain rows that mark
// work in progress with a small pulsing dot.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card reads as one result row of a launcher: the title in the text color with an accessory
// at the right (its status, else its age, where a launcher puts a shortcut hint or a kind), a gray
// subtitle under it (the agent and model, the way a chat names its model under its title), and
// only then the task and where it waits, short. Nothing else: a launcher row never grows a card.
function renderCard(ctx) {
  const card = ctx.card
  const fact = (kind) => card.facts.find((f) => f.kind === kind)
  const subtitle = fact("agent") ?? fact("folder")
  const task = fact("needsInput") ?? fact("task")
  return VStack({ spacing: 3 }, [
    HStack([Text(card.title).lineLimit(1), Spacer(), Text(card.status ?? card.age ?? "").secondary()]),
    subtitle ? Text(subtitle.text).secondary().lineLimit(1) : null,
    task ? Text(task.text).secondary().lineLimit(2) : null,
  ])
}

// Rows: regular weight (a launcher list is all one weight; the selected row's gray fill does the
// pointing) and a small pulsing dot while work runs. Each decoration names its row by id (`row`);
// the title stays the row's own name.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
