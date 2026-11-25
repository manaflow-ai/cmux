// Tandem's sidebar: the hover card as a task card, and rows as the one-line chats and tabs of an
// agent workspace. Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1
// (docs/cmux-next/sidebar-customization.md).

// The card reads like a task card on the new-tab page: a small gray "working for" or age line,
// the title in semibold, then what the agent is doing now as a short step list (an icon and a
// gray line each, as the activity timeline draws its steps), then the branch and pull request.
// What waits on you comes last, in the accent, the color the approval policy wears.
const STEPS = [
  ["editing", "pencil"],
  ["command", "terminal"],
  ["lastReply", "text.bubble"],
]
const WHERE = [
  ["branch", "arrow.triangle.branch"],
  ["pullRequest", "arrow.triangle.pull"],
  ["folder", "folder"],
  ["machine", "desktopcomputer"],
]

function line(icon, text) {
  return HStack({ spacing: 8 }, [Icon(icon).size(12).color("secondary"), Text(text).secondary().lineLimit(1)])
}

function renderCard(ctx) {
  const card = ctx.card
  const find = (kind) => card.facts.find((fact) => fact.kind === kind)
  const task = find("task")
  const needs = find("needsInput")
  const head = [card.status, card.age].filter(Boolean).join(" · ")
  return VStack({ spacing: 6, alignment: "leading" }, [
    head ? Text(head).font("caption").secondary().lineLimit(1) : null,
    Text(card.title).weight("semibold").lineLimit(2),
    task ? Text(task.text).secondary().lineLimit(3) : null,
    ...STEPS.flatMap(([kind, icon]) => card.facts.filter((fact) => fact.kind === kind).map((fact) => line(icon, fact.text))),
    ...WHERE.flatMap(([kind, icon]) => card.facts.filter((fact) => fact.kind === kind).map((fact) => line(icon, fact.text))),
    needs
      ? HStack({ spacing: 6 }, [Icon("hand.raised").size(12).color(cmux.theme.accent), Text(needs.text).weight("medium").color(cmux.theme.accent).lineLimit(2)])
      : null,
  ])
}

// Rows: one line in regular weight, the dotted loader while an agent works. Each decoration names
// its row by id (`row`); the title stays the row's own name, and the icon stays the one you chose,
// as a tab keeps its site's icon.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "braille" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
