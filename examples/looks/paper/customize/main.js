// Paper's sidebar: a reading card with the task in full, and rows that stay calm.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

const FIELDS = ["needsInput", "task", "lastReply", "agent", "folder"]

function renderCard(ctx) {
  const card = ctx.card
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 6 }, [
    Text(card.title).font("headline").lineLimit(2),
    card.status ? Text(card.status).secondary() : null,
    ...facts.map((fact) => Text(fact.text).lineLimit(fact.kind === "task" || fact.kind === "lastReply" ? 4 : 1)),
  ])
}

// Rows: medium names, and the arc as the loading indicator.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ title: () => w().name, weight: () => "medium", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
