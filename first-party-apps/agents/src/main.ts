/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Agent CLIs: which agent CLIs are installed on this Mac, cmux servers and
// the team VM, their versions and latest versions, sign-in state with
// non-secret account labels, and host-run Update, Install and Sign In.
// Data and actions come from the proposed agent_cli.* ops (README).

import { openPane, refresh } from "./actions.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { cycleVariant as cycle, variant } from "./settings.ts"
import { start } from "./store.ts"
import { agentsSection } from "./views/section.ts"
import { byCliView, byMachineView, matrixView } from "./views/variants.ts"

/** Sidebar section `agents`. */
export function renderSection(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return agentsSection()
}

/** Pane kind `agentHub`. */
export function renderPane(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "byMachine":
          return byMachineView()
        case "matrix":
          return matrixView()
        default:
          return byCliView()
      }
    }
  ])
}

export async function openAgents(_args: Record<string, unknown> = {}, ctx?: CmuxCommandContext) {
  await openPane(ctx?.gesture ?? null)
  return {}
}

export async function checkForUpdates() {
  start()
  await refresh()
  return {}
}

export const cycleVariant = cycle
