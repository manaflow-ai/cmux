// A Session Info section, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships).
// It shows in an agent chat's Session Info panel. Save this file while `cmux ext dev` runs: cmux
// redraws it.
import { Panel, Row, section, VStack } from "cmux-extension-sdk"

// The export cmux-app.json names for cmux.session.info.section/1. The context is the chat's
// session: {session_id, cwd, branch?, harness?}.
export const renderSessionInfo = section((context) => {
  const session = context as { cwd?: string; branch?: string; harness?: string }
  return VStack([
    Panel({ title: "Hello from {{TITLE}}" }, [
      Row({ title: session.cwd ?? "no folder", symbol: "folder" }),
      Row({ title: session.branch ?? "no branch", symbol: "arrow.triangle.branch" }),
      Row({ title: session.harness ?? "agent", symbol: "sparkles" }),
    ]),
  ])
})
