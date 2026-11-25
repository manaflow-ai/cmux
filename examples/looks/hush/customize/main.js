// Hush's sidebar: a two-line hover card that says only what matters, and rows that stay still.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: the title in medium weight with the age at the right, then one line of what it is
// doing (or what it asks of you, which takes the place of the task, never both). No accent, no
// list of facts: a calm card is short.
function renderCard(ctx) {
  const card = ctx.card
  const fact = (kind) => card.facts.find((f) => f.kind === kind)
  const line = fact("needsInput") ?? fact("task") ?? fact("lastReply")
  return VStack({ spacing: 4, alignment: "leading" }, [
    HStack({ spacing: 8 }, [Text(card.title).weight("medium").lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    line ? Text(line.text).secondary().lineLimit(2) : card.status ? Text(card.status).secondary().lineLimit(1) : null,
  ])
}

// Rows: regular weight, and a small dot instead of a spinner while work runs. Each decoration
// names its row by id (`row`); the title stays the row's own name, and the icon stays yours.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
