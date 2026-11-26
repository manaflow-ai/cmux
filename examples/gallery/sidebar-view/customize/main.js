// The starter sidebar view: the two sidebar interfaces of the Scene SDK in their smallest form.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1
// (docs/cmux-next/sidebar-customization.md). VStack, HStack, Text, Icon, Spacer, ForEach and
// Group are the SDK's view kit; they follow the theme you wear, so the file names no color.

// The hover card. ctx.card is what the built-in card would show: {title, age, status, facts}.
function renderCard(ctx) {
  const card = ctx.card
  const branch = card.facts.find((fact) => fact.kind === "branch")
  return VStack({ spacing: 4, alignment: "leading" }, [
    HStack({ spacing: 8 }, [Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    card.status ? Text(card.status).secondary().lineLimit(2) : null,
    branch ? HStack({ spacing: 6 }, [Icon("arrow.triangle.branch"), Text(branch.text).secondary().lineLimit(1)]) : null,
  ])
}

// The rows: one decoration per workspace, named by id (`row`). The title stays the row's own
// name; a dot stands in for the spinner while an agent works.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
