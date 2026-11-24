// Overdrive's sidebar: a hover card that leads with the status, like a score card, and rows with
// heavy names and a pulsing dot while work runs.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

const FIELDS = ["needsInput", "agent", "task", "lastReply", "folder"]

function renderCard(ctx) {
  const card = ctx.card
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 4 }, [
    card.status ? Text(card.status).font("caption") : null,
    Text(card.title).font("headline").lineLimit(2),
    ...facts.map((fact) => Text(fact.text).lineLimit(fact.kind === "lastReply" ? 3 : 1)),
  ])
}

// Rows: heavy names, and the dot as the loading indicator.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "bold", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
