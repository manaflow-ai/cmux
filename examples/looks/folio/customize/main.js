// Folio's sidebar: the hover card as a page preview, and rows as the pages of a tree.
// Public surfaces only: cmux.hovercard/1, cmux.sidebar.rows/1 and cmux.session.info.section/1
// (docs/cmux-next/sidebar-customization.md).

// The card reads like hovering a link to a page: the title as a heading, a small gray "edited"
// line, then the page's own text (the task, or the last reply), then its properties as a short
// table, each a gray icon and label on the left and the value beside it, as a database page shows
// them. What needs you comes last, in the link blue, as a call to action at the foot of a page.
const PROPERTIES = [
  ["agent", "sparkles", "Agent"],
  ["folder", "folder", "Folder"],
  ["branch", "arrow.triangle.branch", "Branch"],
  ["pullRequest", "arrow.triangle.pull", "Pull request"],
  ["machine", "desktopcomputer", "Machine"],
]

function property(icon, label, text) {
  return HStack({ spacing: 8 }, [
    Icon(icon).size(12).color("secondary"),
    Text(label).font("caption").secondary().lineLimit(1).frame({ width: 84 }),
    Text(text).font("caption").lineLimit(1),
  ])
}

function renderCard(ctx) {
  const card = ctx.card
  const find = (kind) => card.facts.find((fact) => fact.kind === kind)
  const body = find("task") ?? find("lastReply")
  const needs = find("needsInput")
  const edited = [card.status, card.age ? `edited ${card.age}` : null].filter(Boolean).join(" · ")
  return VStack({ spacing: 6, alignment: "leading" }, [
    Text(card.title).font("headline").weight("semibold").lineLimit(2),
    edited ? Text(edited).font("caption").secondary().lineLimit(1) : null,
    body ? Text(body.text).lineLimit(4) : null,
    ...PROPERTIES.flatMap(([kind, icon, label]) =>
      card.facts.filter((fact) => fact.kind === kind).map((fact) => property(icon, label, fact.text)),
    ),
    needs ? Text(needs.text).weight("medium").color(cmux.theme.accent).lineLimit(2) : null,
  ])
}

// Rows: page titles in regular weight (a tree of pages never bolds a row), and a small dot rather
// than a spinner while work runs. Each decoration names its row by id (`row`); the title stays
// the row's own name, and the icon stays the one you chose, as a page keeps its own icon.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

// Session Info: the chat's page properties, the same short table the hover card ends with (a gray
// icon and label, the value beside it), the way a database page lists its properties above the text.
function renderPageProperties(context) {
  const cwd = String((context && context.cwd) || "")
  const folder = cwd.split("/").filter(Boolean).slice(-2).join("/")
  const branch = String((context && context.branch) || "").trim()
  const agent = String((context && context.harness) || "").trim()
  return VStack({ spacing: 6, alignment: "leading" }, [
    agent ? property("sparkles", "Agent", agent) : null,
    folder ? property("folder", "Folder", folder).help(cwd) : null,
    branch ? property("arrow.triangle.branch", "Branch", branch) : null,
    !folder && !branch && !agent ? Text("Empty").font("caption").secondary() : null,
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows, renderPageProperties }
