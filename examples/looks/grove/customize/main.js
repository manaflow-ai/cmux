// Grove's sidebar: a hover card with a frosted header, like a field note, and rows that stay calm.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).
// Colors are theme tokens (accent, secondary), never hex, so the card follows light and dark live.

// The App's own glass behind a node (paint only, no layout change), where this cmux draws it; an
// older cmux has no .glass and gets the node as it is.
const glass = (node, level) => (typeof node.glass === "function" ? node.glass(level) : node)

// What it waits on first, then the task in full, what the agent said last, and where.
const FIELDS = ["needsInput", "task", "lastReply", "branch", "folder"]
const LINES = { needsInput: 3, task: 4, lastReply: 3 }

function renderCard(ctx) {
  const card = ctx.card
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  const header = HStack({ spacing: 8 }, [
    Icon("leaf").color("accent"),
    Text(card.title).font("headline").lineLimit(2),
    Spacer(),
    Text(card.age ?? "").font("caption").secondary(),
  ])
  return VStack({ spacing: 8 }, [
    glass(header.padding({ top: 6, leading: 8, bottom: 6, trailing: 8 }).cornerRadius(8), "chip"),
    card.status ? Text(card.status).color("accent") : null,
    ...facts.map((fact) => {
      const line = Text(fact.text)
        .lineLimit(LINES[fact.kind] ?? 1)
        .color(fact.kind === "branch" || fact.kind === "folder" ? "secondary" : "primary")
      return fact.kind === "lastReply" ? line.italic() : line
    }),
  ])
}

// Rows: one regular weight for every row, and the arc (a slow-turning ring) while work runs.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ title: () => w().name, weight: () => "regular", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
