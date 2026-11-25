// Basalt's sidebar: the editor's compact hover card and plain one-line rows with a status dot.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: the chat's title in medium weight, then one line per place it works, each led by a
// small gray icon (the branch, then the folder), the way the editor's thread card reads. What it
// waits on comes first, in the accent; the age sits at the right of the title.
const PLACES = ["branch", "folder", "machine"]
const ICONS = { branch: "arrow.triangle.branch", folder: "folder", machine: "laptopcomputer" }

function renderCard(ctx) {
  const card = ctx.card
  const needs = card.facts.find((fact) => fact.kind === "needsInput")
  const places = PLACES.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 6, alignment: "leading" }, [
    HStack({ spacing: 8 }, [
      Text(card.title).weight("medium").lineLimit(1),
      Spacer(),
      Text(card.age ?? "").font("caption").color(cmux.theme.text.secondary),
    ]),
    needs ? Text(needs.text).color(cmux.theme.accent).lineLimit(2) : null,
    ...places.map((fact) =>
      HStack({ spacing: 8 }, [
        Icon(ICONS[fact.kind] ?? "circle").color(cmux.theme.text.secondary),
        Text(fact.text).lineLimit(1),
      ]),
    ),
    card.status ? Text(card.status).font("caption").color(cmux.theme.text.secondary) : null,
  ])
}

// Rows: regular weight, and a small dot while a chat works (amber while it waits on you, gray when
// done: those marks always show). Each decoration names its row by id (`row`); the title stays the
// row's own name, and the icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
