/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Skills and MCP servers: list, install, turn on and off, and remove the
// skills (SKILL.md folders) and MCP servers of every agent, for one project or
// everywhere. Every change is a reviewed diff of the agents' own config files
// before it is written (README "Proposed operations").

import { openPane } from "./actions.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { cycleVariant as cycle, variant } from "./settings.ts"
import { load, start } from "./store.ts"
import { skillsSection } from "./views/section.ts"
import { byAgentView, byScopeView, unifiedView } from "./views/variants.ts"

/** Sidebar section `skills`. */
export function renderSection(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return skillsSection()
}

/** Pane kind `skillsHub`. */
export function renderPane(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "byAgent":
          return byAgentView()
        case "byScope":
          return byScopeView()
        default:
          return unifiedView()
      }
    }
  ])
}

export async function openSkills() {
  await openPane()
  return {}
}

export async function reload() {
  start()
  await load()
  return {}
}

export const cycleVariant = cycle
