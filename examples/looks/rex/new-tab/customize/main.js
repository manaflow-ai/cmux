function renderLauncher() {
  const [machines, setMachines] = signal([])
  const [status, setStatus] = signal("Loading hosts…")
  const [choosingHost, setChoosingHost] = signal(false)
  let reading = false

  async function readHosts() {
    if (reading) return
    reading = true
    setStatus("Loading hosts…")
    try {
      const list = await cmux.call("machine.list", { catalog: true })
      setMachines(list.filter((m) => m.status === "running" && !m.deleted))
      setStatus("")
    } catch (error) {
      setMachines([])
      setStatus(String(error.message || error))
    } finally {
      reading = false
    }
  }

  function perform(id, args = {}) {
    return cmux.actions.run(id, args).catch((error) =>
      cmux.toast({ title: "Couldn’t open the selection", message: String(error.message || error), tone: "warning" }))
  }

  function createOn(machine) {
    return perform("workspace.newOnMachine", { machine: machine.id })
  }

  function entry(title, symbol, action) {
    return Row({ title, symbol }).onTap(action)
  }

  readHosts()
  return VStack({ alignment: "leading", spacing: 4 }, [
    () => choosingHost()
      ? VStack({ alignment: "leading", spacing: 4 }, [
          Button("Back", () => setChoosingHost(false)),
          Text("New Session on Host").font("headline"),
          ForEach({ items: () => machines().filter((m) => m.origin !== "local"), key: (m) => m.id },
            (m) => entry(() => m().name, "desktopcomputer", () => createOn(m()))),
          () => !status() && !machines().some((m) => m.origin !== "local")
            ? Text("No connected remote hosts").font("caption") : null,
          entry("Add Remote Host…", "plus", () => perform("remote.connect"))
        ])
      : VStack({ alignment: "leading", spacing: 4 }, [
          Text("New Tab").font("headline"),
          entry("New Tab in Session", "terminal", () => perform("newSurface")),
          () => {
            const local = machines().find((m) => m.origin === "local")
            return local ? entry("New Local Session", "plus.rectangle.on.rectangle", () => createOn(local)) : null
          },
          entry("New Session on Host…", "desktopcomputer", () => { setChoosingHost(true); readHosts() })
        ]),
    () => status() ? Text(status).font("caption") : null,
    Button("Refresh Hosts", readHosts)
  ]).padding(12)
}

globalThis.__cmuxAppExports = { renderLauncher }
