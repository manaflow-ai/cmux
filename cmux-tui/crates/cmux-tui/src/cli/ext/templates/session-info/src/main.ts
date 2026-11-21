// A Session Info section, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// It shows in an agent chat's Session Info panel. Save this file while `cmux ext dev` runs: cmux
// redraws it. DESIGN.md says how a view should look; this one follows it.
import { cmux, Row, section, VStack } from "cmux-extension-sdk"

/** `/Users/you/src/atlas` -> `atlas`. */
const folderName = (path: string) => path.split("/").filter(Boolean).pop() ?? path

// The export cmux-app.json names for cmux.session.info.section/1. The context is the chat's
// session: {session_id, cwd, branch?, harness?}. The section header already shows the title from
// cmux-app.json, so the rows go straight in: the value as the title, what it is under it.
export const renderSessionInfo = section((context) => {
  const session = context as { cwd?: string; branch?: string; harness?: string }
  return VStack([
    Row({
      title: session.cwd ? folderName(session.cwd) : "No folder",
      subtitle: session.cwd ?? "This chat has no folder",
      symbol: "folder",
    }),
    Row({
      title: session.branch ?? "No branch",
      subtitle: "Branch",
      symbol: "arrow.triangle.branch",
      tint: session.branch ? null : cmux.theme.text.tertiary,
    }),
    Row({ title: session.harness ?? "Agent", subtitle: "Agent", symbol: "sparkles" }),
  ])
})
