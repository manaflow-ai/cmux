function renderLauncher() {
  function run(id, args = {}) {
    return cmux.actions.run(id, args).catch(error => cmux.toast({
      title: "Couldn’t open the selection",
      message: String(error.message || error),
      tone: "warning"
    }))
  }

  return VStack({ alignment: "leading", spacing: 4 }, [
    Text("New Tab").font("headline"),
    Row({ title: "New Tab in Session", symbol: "terminal" })
      .onTap(() => run("newSurface")),
    Row({ title: "New Local Session", symbol: "plus.rectangle.on.rectangle" })
      .onTap(() => run("workspace.newOnMachine", { machine: "local" })),
    Row({ title: "New Session on Host…", symbol: "desktopcomputer" })
      .onTap(() => run("palette.open", { query: "New Workspace on Machine" })),
    Row({ title: "Add Remote Host…", symbol: "plus" })
      .onTap(() => run("remote.connect"))
  ]).padding(12)
}

globalThis.__cmuxAppExports = { renderLauncher }
