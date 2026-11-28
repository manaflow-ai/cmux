// Session Info supplies the thread ID. chat.list supplies its machine, working folder and workspace.
function renderOpenIn(context) {
  const chats = cmux.watch("chat.list")
  const launch = (chat, app) => cmux.call("tab.create_terminal", {
    workspace: chat.workspace,
    cwd: chat.cwd,
    name: "Open in " + app,
    argv: ["/usr/bin/open", "-a", app, chat.cwd]
  }).catch(error => cmux.toast({ title: "Open in " + app, message: String(error), tone: "warning" }))

  return VStack({ spacing: 4 }, [
    () => {
      if (chats.error()) return Text(String(chats.error())).font("caption")
      if (!chats.value()) return ProgressView()
      const matches = chats.value().filter(chat => chat.id === context.session_id)
      const chat = matches.length === 1 ? matches[0] : null
      if (!chat || chat.machine || !chat.workspace || !chat.cwd || !chat.cwd.startsWith("/"))
        return Text("Open a local thread with a project folder to choose an editor.").font("caption")
      return Menu("Open folder in…", [
        Button("Cursor", () => launch(chat, "Cursor")),
        Button("VS Code", () => launch(chat, "Visual Studio Code")),
        Button("Finder", () => launch(chat, "Finder"))
      ]).help(chat.cwd)
    }
  ])
}

globalThis.__cmuxAppExports = { renderOpenIn }
