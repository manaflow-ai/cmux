// Apple's sidebar: a hover card laid out like a macOS popover or a Finder Get Info header, and
// source-list rows with the system's own spinner.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: a bold title with the age at the right, the status in the secondary label under it,
// what it asks of you in the label color, then the details as quiet secondary lines, the way a
// popover or Mail's message header reads: one title, gray facts under it.
const PRIMARY = ["needsInput", "task"]
const SECONDARY = ["folder", "branch", "pullRequest", "agent"]

function renderCard(ctx) {
  const card = ctx.card
  const pick = (kinds) => kinds.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 3 }, [
    HStack([Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    card.status ? Text(card.status).secondary().lineLimit(1) : null,
    ...pick(PRIMARY).map((fact) => Text(fact.text).lineLimit(fact.kind === "task" ? 3 : 2)),
    ...pick(SECONDARY).map((fact) => Text(fact.text).secondary().lineLimit(1)),
  ])
}

// Rows: regular weight (a source list never bolds its rows) and the native indicator, the system
// spinner while work runs. Each decoration names its row by id (`row`); the title stays the row's
// own name, and the icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "native" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
