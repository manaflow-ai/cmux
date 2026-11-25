// Buttons that run the person's own actions from ~/.config/cmux/cmux-next.json. Each action
// there registers as `cmuxConfig.<name>`, so the same command is also in the Command Palette
// and can take a shortcut. Clicking needs actions:run, which the person turns on in
// Settings > Apps > My views; until then a click shows a toast that says so.

// One entry per action in cmux-next.json "actions" (its key is the name).
const commands = [
  { name: "tests", title: "Run tests", symbol: "checkmark.seal" },
  { name: "dev-server", title: "Start dev server", symbol: "play" },
  { name: "git-status", title: "Git status", symbol: "arrow.triangle.branch" }
]

const [last, setLast] = signal(null) // the last command run, for the row under the buttons

async function run(command) {
  try {
    await cmux.actions.run(`cmuxConfig.${command.name}`)
    setLast(command.title)
  } catch (e) {
    const scopeOff = e && e.code === "scope.missing"
    cmux.toast({
      title: scopeOff ? "Turn on Run actions for My views" : `Cannot run ${command.title}`,
      message: scopeOff ? "Settings > Apps > My views" : e instanceof Error ? e.message : String(e),
      tone: "warning"
    })
  }
}

function renderCommands() {
  return VStack([
    Panel({ title: "Commands" }, commands.map((command) => Button(command.title, () => run(command)))),
    () => (last() ? Row({ title: () => `Ran ${last()}`, symbol: "checkmark.circle", tint: cmux.theme.success }) : null)
  ])
}

globalThis.__cmuxAppExports = { renderCommands }
