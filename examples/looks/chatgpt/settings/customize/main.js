function renderSettings() {
  const open = (action, args = {}) => cmux.actions.run(action, args).catch(error => cmux.toast({ title: "Settings", message: String(error), tone: "warning" }))
  return VStack({ spacing: 4 }, [
    Button("Settings…", () => open("openSettings")),
    Button("Appearance", () => open("openSettings", { setting: "appearance.themeFile" })),
    Button("Chat font", () => open("openSettings", { setting: "agentPane.display.font.size" })),
    Button("Keyboard shortcuts", () => open("keybindings.open"))
  ])
}

globalThis.__cmuxAppExports = { renderSettings }
