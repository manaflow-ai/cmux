// Material's sidebar: the hover card as an M3 rich tooltip and the rows as navigation drawer items.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The rich tooltip (m3.material.io/components/tooltips/specs): a subhead in Title Small, supporting
// text in Body Medium on on-surface-variant, then what needs you as the action, in primary.
// Facts read as one-line list items with a leading icon, as an M3 list draws them.
const FACTS = ["branch", "pullRequest", "agent", "folder"]
const ICONS = {
  branch: "arrow.triangle.branch",
  pullRequest: "arrow.triangle.pull",
  agent: "sparkles",
  folder: "folder",
}

function renderCard(ctx) {
  const card = ctx.card
  const supporting = card.facts.find((fact) => fact.kind === "task") ?? card.facts.find((fact) => fact.kind === "lastReply")
  const needs = card.facts.find((fact) => fact.kind === "needsInput")
  const facts = FACTS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 8, alignment: "leading" }, [
    HStack({ spacing: 8 }, [
      Text(card.title).font("headline").weight("medium").lineLimit(1),
      Spacer(),
      Text(card.age ?? "").font("caption").color(cmux.theme.text.secondary),
    ]),
    card.status ? Text(card.status).font("caption").weight("medium").color(cmux.theme.text.secondary) : null,
    supporting ? Text(supporting.text).color(cmux.theme.text.secondary).lineLimit(3) : null,
    ...facts.map((fact) =>
      HStack({ spacing: 12 }, [Icon(ICONS[fact.kind] ?? "circle").color(cmux.theme.text.secondary), Text(fact.text).lineLimit(1)]),
    ),
    needs ? Text(needs.text).weight("medium").color(cmux.theme.accent).lineLimit(2) : null,
  ])
}

// Drawer items: labels in Label Large (medium weight), and M3's circular progress indicator, the
// arc, while a thread works. Each decoration names its row by id (`row`); the title stays the
// row's own name.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "medium", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
