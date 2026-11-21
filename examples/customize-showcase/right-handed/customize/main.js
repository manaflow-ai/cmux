// Right-handed: the profile's settings move the sidebar, the prompt rail, the Session Info chip
// and the Chief's dock to the other side. The hover card opens toward the work from a sidebar on
// the right, so it is shorter here: what waits on you, the agent, the branch, and the PR.

const FIELDS = ["needsInput", "notification", "agent", "branch", "pullRequest"]
const ICONS = { needsInput: "questionmark.bubble", notification: "bell", agent: "sparkles", branch: "arrow.triangle.branch", pullRequest: "arrow.triangle.pull" }

// ctx.card is what the built-in card would show: {title, status, facts: [{kind, text}]}.
function renderCard(ctx) {
  const card = ctx.card
  const facts = FIELDS.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 5 }, [
    HStack({ spacing: 6 }, [Spacer(), Text(card.title).bold().lineLimit(1)]),
    card.status ? HStack([Spacer(), Text(card.status).secondary()]) : null,
    ...facts.map((fact) => HStack({ spacing: 6 }, [Spacer(), Text(fact.text).lineLimit(1), Icon(ICONS[fact.kind] ?? "circle")]))
  ])
}

globalThis.__cmuxAppExports = { renderCard }
