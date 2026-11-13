// Three buttons wired to built-in cmux actions. A local/customize app can use cmuxConfig IDs.
function run(id) {
  cmux.actions.run(id).catch((e) => cmux.toast({
    title: "Action unavailable", message: e instanceof Error ? e.message : String(e), tone: "warning"
  }))
}
function renderCommands() {
  return VStack({ spacing: 2 }, [
    Text("Quick actions").font("headline"),
    Button("New workspace", () => run("newTab")),
    Button("New browser", () => run("newBrowserWorkspace")),
    Button("Toggle sidebar", () => run("toggleSidebar"))
  ])
}
globalThis.__cmuxAppExports = { renderCommands }
