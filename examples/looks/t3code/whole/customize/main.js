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

function renderProjectPicker() {
  const [isOpen, setOpen] = signal(false)
  const [query, setQuery] = signal("")
  const [projects, setProjects] = signal([])
  const [status, setStatus] = signal("")
  let request = 0

  async function search(text) {
    const revision = ++request
    setQuery(text)
    setProjects([])
    setStatus("Searching…")
    try {
      const result = await cmux.call("project.list", { query: text.trim(), limit: 25 })
      if (revision !== request) return
      const matches = result.projects.filter((project) => project.state === "present")
      setProjects(matches)
      setStatus(matches.length ? "" : "No matching projects")
    } catch (error) {
      if (revision === request) setStatus(String(error.message || error))
    }
  }

  function togglePicker() {
    setOpen(!isOpen())
    if (isOpen()) search("")
    else request++
  }

  async function openProject(action, args) {
    try {
      await cmux.actions.run(action, args)
      setOpen(false)
      request++
    } catch (error) {
      setStatus(String(error.message || error))
    }
  }

  return VStack({ alignment: "leading", spacing: 4 }, [
    Button("Choose project…", togglePicker),
    () => isOpen() ? VStack({ alignment: "leading", spacing: 3 }, [
      TextField(query, { placeholder: "Search projects", onEdit: search, onCancel: togglePicker }),
      ForEach({ items: projects, key: (project) => project.path }, (project) =>
        Button(
          Row({ title: () => project().name, subtitle: () => project().path, symbol: "folder" }),
          () => openProject("palette.newAgentChat", { cwd: project().path })
        )
      ),
      () => status() ? Text(status()).font("caption") : null,
      Button("Add project…", () => openProject("openFolder", {}))
    ]) : null
  ])
}

function renderEditor() {
  return Button("Open in VS Code", async () => {
    try {
      await cmux.actions.run("palette.terminalOpenDirectory", { app: "com.microsoft.VSCode" })
    } catch (error) {
      cmux.toast({ title: "Couldn’t open the folder", message: String(error.message || error), tone: "warning" })
    }
  })
}

globalThis.__cmuxAppExports = { renderThreadCard, renderProjectPicker, renderEditor }
