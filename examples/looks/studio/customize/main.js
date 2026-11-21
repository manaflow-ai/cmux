// Studio's sidebar: a terse hover card and plain rows with a dot while work runs.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: the title, what it is doing, and where. Nothing else.
const FIELDS = ["needsInput", "task", "branch", "pullRequest"]

function renderCard(ctx) {
  const card = ctx.card
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 4 }, [
    HStack([Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    card.status ? Text(card.status).secondary() : null,
    ...facts.map((fact) => Text(fact.text).lineLimit(fact.kind === "task" ? 2 : 1)),
  ])
}

// Rows: no icons, regular weight, and the small dot as the loading indicator.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
