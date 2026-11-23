// The host supplies the hovered workspace and its activity in ctx.card.
function renderThreadCard({ card }) {
  const project = card.facts.find((fact) => fact.kind === "folder")
  const details = card.facts.filter((fact) =>
    ["needsInput", "branch", "pullRequest", "machine", "agent"].includes(fact.kind)
  )
  return VStack({ spacing: 4, alignment: "leading" }, [
    HStack({ spacing: 6 }, [
      project ? Text(project.text).font("caption").secondary().lineLimit(1) : null,
      Spacer(),
      card.age ? Text(card.age).font("caption").secondary() : null,
    ]),
    Text(card.title).weight("medium").lineLimit(2),
    card.status ? Text(card.status).font("caption") : null,
    ...details.map((fact) => Text(fact.text).font("caption").secondary().lineLimit(2)),
  ])
}

globalThis.__cmuxAppExports = { renderThreadCard }
