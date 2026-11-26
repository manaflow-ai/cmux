// Grid's sidebar: a hover card set like a table, and rows in a heavy grotesk weight.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: the title in bold with the status at its right, then one fact per line, each a label
// column and a value, on 8 px steps. What it waits on comes first, in the accent: the one place
// the card uses color.
const FACTS = ["branch", "pullRequest", "folder", "agent", "machine"]
const LABELS = { branch: "Branch", pullRequest: "PR", folder: "Folder", agent: "Agent", machine: "Machine" }

function row(label, text) {
  return HStack({ spacing: 8 }, [
    Text(label).font("caption").weight("semibold").color(cmux.theme.text.secondary).lineLimit(1),
    Spacer(),
    Text(text).font("caption").lineLimit(1),
  ])
}

function renderCard(ctx) {
  const card = ctx.card
  const needs = card.facts.find((fact) => fact.kind === "needsInput")
  const facts = FACTS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 8, alignment: "leading" }, [
    HStack({ spacing: 8 }, [
      Text(card.title).weight("bold").lineLimit(1),
      Spacer(),
      card.status ? Text(card.status).font("caption").weight("semibold").lineLimit(1) : null,
    ]),
    needs ? Text(needs.text).color(cmux.theme.accent).lineLimit(2) : null,
    ...facts.map((fact) => row(LABELS[fact.kind] ?? fact.kind, fact.text)),
    card.age ? row("Active", card.age) : null,
  ])
}

// Rows: semibold names, and a small dot while a chat works (waiting, error and done marks always
// show). Each decoration names its row by id (`row`); the title stays the row's own name, and the
// icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "semibold", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
