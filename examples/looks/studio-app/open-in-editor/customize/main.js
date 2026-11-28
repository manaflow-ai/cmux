function renderEditor() {
  return Button("Open in VS Code", async () => {
    try {
      await cmux.actions.run("palette.terminalOpenDirectory", { app: "com.microsoft.VSCode" })
    } catch (error) {
      cmux.toast({ title: "Couldn’t open the folder", message: String(error.message || error), tone: "warning" })
    }
  })
}

globalThis.__cmuxAppExports = { renderEditor }
