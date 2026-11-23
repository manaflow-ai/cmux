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

globalThis.__cmuxAppExports = { renderProjectPicker }
