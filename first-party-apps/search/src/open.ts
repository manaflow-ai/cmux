/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Opening a result. Called only from tap and submit handlers, which run with
// origin `user`, so the owners accept the focus change. Automation (the
// `search` command) never calls this: it returns each hit's target instead.

import type { Hit } from "./model.ts"

export async function openHit(hit: Hit): Promise<void> {
  const t = hit.target
  switch (t.op) {
    case "workspace.focus":
      await cmux.workspace.focus(t.params)
      return
    case "tab.focus":
      await cmux.tab.focus(t.params)
      if (t.reveal) {
        // Proposed: scroll the terminal so the matched row is visible. Without it the tab opens at its current scroll position.
        await cmux.call("terminal.viewport.reveal", { terminal: t.reveal.terminal, row: t.reveal.row }).catch(() => undefined)
      }
      return
    case "action.run":
      await cmux.actions.run(t.params.id, t.params.args)
      return
  }
}
