// Prism's sidebar: a hover card laid out like a browser's link preview, and rows that read as
// tabs with a spinning arc while work runs.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card, as a link preview reads: the "site" first (the folder, small and gray, the way a
// preview names the domain), then the title in bold, then what it is doing, and what it asks of
// you in the accent, the one loud line. Branch and agent close it as one quiet line each.
function renderCard(ctx) {
  const card = ctx.card
  const fact = (kind) => card.facts.find((f) => f.kind === kind)
  const folder = fact("folder")
  const task = fact("task") ?? fact("lastReply")
  const needs = fact("needsInput")
  const quiet = ["branch", "agent"].map(fact).filter(Boolean)
  return VStack({ spacing: 4, alignment: "leading" }, [
    HStack({ spacing: 6 }, [
      folder ? Text(folder.text).font("caption").secondary().lineLimit(1) : null,
      Spacer(),
      Text(card.age ?? "").font("caption").secondary(),
    ]),
    Text(card.title).font("headline").bold().lineLimit(2),
    card.status ? Text(card.status).secondary().lineLimit(1) : null,
    task ? Text(task.text).lineLimit(3) : null,
    needs ? Text(needs.text).weight("semibold").color(cmux.theme.accent).lineLimit(2) : null,
    ...quiet.map((f) => Text(f.text).font("caption").secondary().lineLimit(1)),
  ])
}

// Rows: tab titles in medium weight, as the sidebar's tabs draw, and the spinning arc while work
// runs. Each decoration names its row by id (`row`); the title stays the row's own name, and the
// icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "medium", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
