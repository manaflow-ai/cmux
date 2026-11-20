// Tachyon's sidebar: a session hover card laid out the way a modern terminal shows a session, and
// rows with a filling arc while work runs.
// Public surfaces only: cmux.hovercard/1, cmux.sidebar.rows/1 and cmux.session.info.section/1
// (docs/cmux-next/sidebar-customization.md).

// The card: the status first, as a small tinted chip ("In progress"), then the session's place
// (folder, then branch), the title in the monospaced face (it is usually a command or a prompt),
// what it asks of you in the accent, and the agent last in the quiet gray, with the age at its
// right. No headline: the chip carries the state, the mono line carries the identity.
const PLACE = ["folder", "branch"]
const ICONS = { folder: "folder", branch: "arrow.triangle.branch", pullRequest: "arrow.triangle.pull" }

function chip(text) {
  return Text(text).font("caption").weight("medium").lineLimit(1).fixedSize("horizontal")
    .paddingHorizontal(6).paddingVertical(2).cornerRadius(4).background("badge")
}

function place(fact) {
  return HStack({ spacing: 6 }, [
    Icon(ICONS[fact.kind] ?? "circle").size(12).color("secondary"),
    Text(fact.text).lineLimit(1),
  ])
}

function renderCard(ctx) {
  const card = ctx.card
  const find = (kind) => card.facts.find((fact) => fact.kind === kind)
  const needs = find("needsInput")
  const task = find("task") ?? find("command")
  const agent = find("agent")
  const pr = find("pullRequest")
  return VStack({ spacing: 6, alignment: "leading" }, [
    card.status ? HStack([chip(card.status), Spacer()]) : null,
    ...PLACE.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind)).map(place),
    Text(card.title).monospaced().lineLimit(1),
    task ? Text(task.text).monospaced().secondary().lineLimit(2) : null,
    needs ? Text(needs.text).color(cmux.theme.accent).lineLimit(3) : null,
    pr ? place(pr) : null,
    HStack({ spacing: 6 }, [
      agent ? Text(agent.text).font("caption").secondary().lineLimit(1) : null,
      Spacer(),
      Text(card.age ?? "").font("caption").secondary(),
    ]),
  ])
}

// Rows: regular weight (the title is a session name, often a command), and the thin arc that fills
// while an agent works. Each decoration names its row by id (`row`); the title stays the row's own
// name, and the icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "arc" }, []),
    ),
  ])
}

// Session Info: the session as the prompt line a terminal prints before each block, in the
// monospaced face: the folder, then the branch in the accent, then the agent in the quiet gray.
function renderPrompt(context) {
  const cwd = String((context && context.cwd) || "")
  const folder = cwd.split("/").filter(Boolean).slice(-2).join("/")
  const branch = String((context && context.branch) || "").trim()
  const agent = String((context && context.harness) || "").trim()
  return VStack({ spacing: 4, alignment: "leading" }, [
    HStack({ spacing: 6 }, [
      Text(folder ? `~/${folder}` : "~").monospaced().lineLimit(1).truncation("head").help(cwd),
      branch ? Text(branch).monospaced().color(cmux.theme.accent).lineLimit(1) : null,
      Spacer(),
    ]),
    agent ? Text(agent).monospaced().font("caption").secondary().lineLimit(1) : null,
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows, renderPrompt }
