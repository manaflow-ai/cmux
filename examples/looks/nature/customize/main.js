// Nature's hover card: the title, the status on a small chip of the app's own glass, what the agent
// is doing, and where. Public surfaces only: cmux.hovercard/1 (docs/cmux-next/sidebar-customization.md)
// and `.glass(level)` (docs/cmux-next/glass.md).
//
// Hierarchy: the title reads first (bold, primary ink), the status chip second (one colored mark
// plus words, so color is never the only signal), the task third, and where it runs last in
// secondary ink. Every color is a theme token, so light, dark and Reduce Transparency follow the
// theme; the accent appears once, on the status mark of running work.

// An app from before `.glass` draws the chip without glass instead of throwing.
const glass = (node, level) => (typeof node.glass === "function" ? node.glass(level) : node)

// The status's mark: its tone and an SF Symbol, so the state reads in shape as well as color.
function statusMark(status) {
  const text = (status ?? "").toLowerCase()
  if (/input|wait|approv|permission/.test(text)) return { tone: "warning", symbol: "exclamationmark.circle.fill" }
  if (/error|fail/.test(text)) return { tone: "danger", symbol: "xmark.circle.fill" }
  if (/done|finish|complete/.test(text)) return { tone: "success", symbol: "checkmark.circle.fill" }
  return { tone: "accent", symbol: "circle.dotted.circle" }
}

// Where it runs: branch, pull request and machine, on one quiet line.
const WHERE = ["branch", "pullRequest", "machine"]

function renderCard(ctx) {
  const card = ctx.card
  const fact = (kind) => card.facts.find((f) => f.kind === kind)
  const ask = fact("needsInput")
  const task = fact("task") ?? fact("lastReply")
  const where = WHERE.map(fact)
    .filter(Boolean)
    .map((f) => f.text)
    .join("  ·  ")

  const mark = statusMark(card.status)
  const chip = card.status
    ? glass(
        HStack({ spacing: 4 }, [
          Icon(mark.symbol).color(mark.tone).font(11),
          Text(card.status).font(11).weight("medium").lineLimit(1),
        ])
          .paddingHorizontal(8)
          .paddingVertical(4)
          .cornerRadius(8),
        "chip",
      )
    : null

  return VStack({ spacing: 8 }, [
    HStack({ spacing: 8 }, [
      Text(card.title).bold().lineLimit(1),
      Spacer(),
      Text(card.age ?? "").font(11).secondary(),
    ]),
    chip,
    ask ? Text(ask.text).lineLimit(3) : null,
    task && !ask ? Text(task.text).lineLimit(3) : null,
    where ? Text(where).font(11).secondary().lineLimit(1) : null,
  ])
}

globalThis.__cmuxAppExports = { renderCard }
