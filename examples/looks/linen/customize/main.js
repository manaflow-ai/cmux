// Linen's sidebar: a preview hover card and plain history rows with a spinner.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).

// The card: the chat's title with its age at the right, then a short preview of what it is doing
// (its prompt, or its last reply), in gray, then where it runs. What it waits on comes first.
// It reads like a message preview, not a fact sheet: two or three lines, no labels.
function renderCard(ctx) {
  const card = ctx.card
  const needs = card.facts.find((fact) => fact.kind === "needsInput")
  const preview = card.facts.find((fact) => fact.kind === "lastReply") ?? card.facts.find((fact) => fact.kind === "task")
  const where = card.facts.find((fact) => fact.kind === "machine") ?? card.facts.find((fact) => fact.kind === "folder")
  return VStack({ spacing: 4, alignment: "leading" }, [
    HStack({ spacing: 8 }, [
      Text(card.title).weight("medium").lineLimit(1),
      Spacer(),
      Text(card.age ?? "").color(cmux.theme.text.secondary),
    ]),
    needs ? Text(needs.text).weight("medium").lineLimit(2) : null,
    preview ? Text(preview.text).color(cmux.theme.text.secondary).lineLimit(3) : null,
    where ? Text(where.text).font("caption").color(cmux.theme.text.secondary).lineLimit(1) : null,
  ])
}

// Rows: regular weight (history never bolds a title), and a thin spinning ring while a chat works.
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
