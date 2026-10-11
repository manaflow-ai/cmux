/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Agent memory: browse, search, edit and delete agent memory files (CLAUDE.md,
// AGENTS.md, Claude project memory, other agents' equivalents) per machine and
// project. Files arrive only as root and document handles; every write shows a
// diff first and deletes go to the Trash (README "Proposed operations").

import { openPane } from "./actions.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { cycleVariant as cycle, variant } from "./settings.ts"
import { load, start } from "./store.ts"
import { memorySection } from "./views/section.ts"
import { entriesView, filesView, splitView } from "./views/variants.ts"

/** Sidebar section `memory`. */
export function renderSection(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return memorySection()
}

/** Pane kind `memoryHub`. */
export function renderPane(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "entries":
          return entriesView()
        case "split":
          return splitView()
        default:
          return filesView()
      }
    }
  ])
}

export async function openMemory(_args: Record<string, unknown> = {}, ctx?: CmuxCommandContext) {
  await openPane(ctx?.gesture ?? null)
  return {}
}

export async function reload() {
  start()
  await load()
  return {}
}

export const cycleVariant = cycle
