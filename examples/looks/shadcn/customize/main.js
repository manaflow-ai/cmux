// shadcn's sidebar: the hover card is shadcn's HoverCard, and rows are sidebar-07's quiet menu items.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card, as the HoverCard demo lays it out: the title in text-sm font-semibold with the status
// as an outline <Badge> (rounded-md, border, px-2 py-0.5, text-xs font-medium) at its right; the
// task as the text-sm description; then text-xs muted-foreground lines, each behind a small icon,
// ending with the age as the demo's "Joined December 2021" line.
const META = ["branch", "pullRequest", "folder", "agent", "machine"]
const ICONS = {
  needsInput: "questionmark.bubble",
  branch: "arrow.triangle.branch",
  pullRequest: "arrow.triangle.pull",
  folder: "folder",
  agent: "sparkles",
  machine: "desktopcomputer",
  age: "calendar",
}

// <Badge variant="outline">, or variant="secondary" (bg-secondary, no border) when it needs you.
function badge(text, needsYou) {
  const node = Text(text).font("caption").weight("medium").lineLimit(1).fixedSize("horizontal")
    .paddingHorizontal(8).paddingVertical(2).cornerRadius(6)
  return needsYou ? node.background("badge") : node.borderColor("separator").borderWidth(1)
}

function meta(kind, text) {
  return HStack({ spacing: 6 }, [
    Icon(ICONS[kind] ?? "circle").size(12).color("secondary"),
    Text(text).font("caption").secondary().lineLimit(1),
  ])
}

function renderCard(ctx) {
  const card = ctx.card
  const find = (kind) => card.facts.find((fact) => fact.kind === kind)
  const task = find("task")
  const needs = find("needsInput")
  const facts = META.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 8 }, [
      Text(card.title).weight("semibold").lineLimit(1),
      Spacer(),
      card.status ? badge(card.status, Boolean(needs)) : null,
    ]),
    needs ? Text(needs.text).lineLimit(3) : null,
    task ? Text(task.text).lineLimit(3) : null,
    VStack({ spacing: 4 }, [
      ...facts.map((fact) => meta(fact.kind, fact.text)),
      card.age ? meta("age", `Active ${card.age} ago`) : null,
    ]),
  ])
}

// Rows: SidebarMenuButton's regular-weight text-sm label, and a small dot while work runs (no
// spinner). Each decoration names its row by id (`row`); the title stays the row's own name.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
