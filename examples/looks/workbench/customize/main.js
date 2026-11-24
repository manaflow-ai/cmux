// Workbench's sidebar: a terse card that leads with where the work is, and rows that stay dense.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

const FIELDS = ["needsInput", "folder", "agent", "task", "lastReply"]

function renderCard(ctx) {
  const card = ctx.card
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 4 }, [
    Text(card.title).font("headline").lineLimit(1),
    card.status ? Text(card.status).secondary() : null,
    ...facts.map((fact) => Text(fact.text).lineLimit(fact.kind === "task" || fact.kind === "lastReply" ? 2 : 1)),
  ])
}

// Rows: regular-weight names, and a braille spinner as the loading indicator.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "braille" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
