// Studio's sidebar: a thread card that leads with the project, then the title, then what needs you.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: folder and age on the top line, the title under it, then approval, branch and PR.
const FIELDS = ["needsInput", "branch", "pullRequest", "agent"]

function renderCard(ctx) {
  const card = ctx.card
  const folder = card.facts.find((fact) => fact.kind === "folder")
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 4 }, [
    HStack([Text(folder ? folder.text : "").secondary().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    Text(card.title).bold().lineLimit(1),
    card.status ? Text(card.status).secondary() : null,
    ...facts.map((fact) => Text(fact.text).lineLimit(1)),
  ])
}

// Rows: regular-weight titles and a small dot while a thread works. Each decoration names its row by
// id (`row`), which every cmux build matches; the title stays the row's own name.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
