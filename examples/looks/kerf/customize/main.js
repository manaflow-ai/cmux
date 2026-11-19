// Kerf's sidebar: a hover card that reads like an editor's list item and tooltip, and plain rows
// with a thin arc while a thread works.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: one dense block, as the threads list and its tooltip draw a thread. The title in the
// regular weight with the age at the right in the muted gray; then one line of facts (branch, pull
// request) with small icons; then the task and what it waits on, each one line or two; the agent
// last. Tight 2 pt spacing, nothing bold, nothing colored but what needs you (the accent).
const ICONS = { branch: "arrow.triangle.branch", pullRequest: "arrow.triangle.pull", folder: "folder" }

function fact(f) {
  return HStack({ spacing: 4 }, [Icon(ICONS[f.kind] ?? "circle").size(11).color("secondary"), Text(f.text).font("caption").secondary().lineLimit(1)])
}

function renderCard(ctx) {
  const card = ctx.card
  const find = (kind) => card.facts.find((f) => f.kind === kind)
  const needs = find("needsInput")
  const task = find("task") ?? find("lastReply")
  const agent = find("agent")
  const place = ["branch", "pullRequest", "folder"].map(find).filter(Boolean)
  return VStack({ spacing: 2, alignment: "leading" }, [
    HStack({ spacing: 8 }, [Text(card.title).lineLimit(1), Spacer(), Text(card.age ?? "").font("caption").secondary()]),
    place.length ? HStack({ spacing: 10 }, place.map(fact)) : null,
    card.status ? Text(card.status).font("caption").secondary().lineLimit(1) : null,
    task ? Text(task.text).secondary().lineLimit(2) : null,
    needs ? Text(needs.text).color(cmux.theme.accent).lineLimit(2) : null,
    agent ? Text(agent.text).font("caption").secondary().lineLimit(1) : null,
  ])
}

// Rows: regular weight (an editor never bolds a list item) and the thin arc while a thread works.
// Each decoration names its row by id (`row`); the title stays the row's own name, and the icon
// stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
