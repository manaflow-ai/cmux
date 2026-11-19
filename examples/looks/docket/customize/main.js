// Docket's sidebar: a hover card laid out like an inbox notification, and rows that mark work in
// progress with the thin arc.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card reads as one inbox row: the title with the age at the right ("1h"), then one gray line
// with why it wants you (what it waits on, the unread notification, else its status), then the
// task, then the facts as quiet gray lines: identity, subject and reason on three lines, the way a
// tracker's inbox keeps an update from turning into a card of its own.
const REASON = ["needsInput", "notification", "unread"]
const FACTS = ["branch", "pullRequest", "folder", "agent"]

function renderCard(ctx) {
  const card = ctx.card
  const pick = (kinds) => kinds.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  const reason = pick(REASON)[0]
  const task = pick(["task"])[0]
  return VStack({ spacing: 2 }, [
    HStack([Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    reason ? Text(reason.text).secondary().lineLimit(2) : card.status ? Text(card.status).secondary().lineLimit(1) : null,
    task ? Text(task.text).lineLimit(3) : null,
    ...pick(FACTS).map((fact) => Text(fact.text).secondary().lineLimit(1)),
  ])
}

// Rows: regular weight (a dense list never bolds its rows) and the thin arc while work runs, the
// tracker's state ring that fills as work moves. Each decoration names its row by id (`row`); the
// title stays the row's own name, and the icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
