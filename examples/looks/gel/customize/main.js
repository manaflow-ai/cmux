// Gel's sidebar: a hover card built from tonal containers, and calm rows with the arc while work runs.
// Public surfaces only: cmux.hovercard/1 and cmux.sidebar.rows/1 (docs/cmux-next/sidebar-customization.md).
// Colors are the theme's semantic tokens (`selected`, `accent`, `secondary`), so the card follows light
// and dark live; no hex color is written here.

// The App's own glass under a node (paint only, no layout change). An older cmux has no `.glass`, so the
// node draws without it rather than throwing.
const glass = (node, level) => (typeof node.glass === "function" ? node.glass(level) : node)

// Two kinds of chip, both caption text with a soft 8 pt corner. A state chip floats on the App's chip
// glass (`.glass` replaces `.background` where the App has it, so an older cmux shows the tonal fill);
// a place chip is a filled tonal container in the theme's `selected` tone.
const pad = (node) =>
  node.font("caption").weight("medium").lineLimit(1).paddingHorizontal(8).paddingVertical(3).cornerRadius(8)
const stateChip = (text) => glass(pad(Text(text)).background("selected"), "chip")
const placeChip = (text) => pad(Text(text)).background("selected")

const fact = (card, kind) => card.facts.find((f) => f.kind === kind)

// The card: what it is and its state on one line, why it waits (the one thing that may need you),
// what it was asked, and where it is, as chips.
function renderCard(ctx) {
  const card = ctx.card
  const waiting = fact(card, "needsInput")
  const task = fact(card, "task")
  const reply = fact(card, "lastReply")
  const where = ["branch", "pullRequest"].map((kind) => fact(card, kind)).filter(Boolean)
  return VStack({ spacing: 8 }, [
    HStack({ spacing: 8 }, [
      Text(card.title).font("headline").lineLimit(2),
      Spacer(),
      card.status ? stateChip(card.status) : Text(card.age ?? "").font("caption").secondary(),
    ]),
    waiting ? Text(waiting.text).color("accent").weight("medium").lineLimit(3) : null,
    task ? Text(task.text).lineLimit(3) : null,
    reply ? Text(reply.text).secondary().lineLimit(2) : null,
    where.length ? HStack({ spacing: 4 }, where.map((f) => placeChip(f.text))) : null,
  ])
}

// Rows: medium names, and the circular arc as the loading indicator.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ title: () => w().name, weight: () => "medium", indicator: () => "arc" }, []),
    ),
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows }
