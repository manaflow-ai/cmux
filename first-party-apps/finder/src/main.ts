/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Finder: browse local folders, cmux servers, the team VM and SSH hosts; copy,
// move, rename and trash through the owners; preview; send files to terminals
// and agents. Built as a third-party app would be: it sees only handles the
// user gave it (roots, connections), never absolute paths or credentials.
// Platform proposal: plans/cmux-next/finder.md.

import { ops } from "./data/ops.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { cycleVariant as cycle, showPreview, variant } from "./settings.ts"
import { start } from "./store.ts"
import { addFolder as pickFolder, connect, filesSection } from "./views/sidebar.ts"
import { columnsView, dualPaneView, listPreviewView } from "./views/variants.ts"

/** Sidebar section "Files". */
export function renderFiles(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return filesSection()
}

/** Pane kind `finder`. */
export function renderFinder(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  start()
  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "columns":
          return columnsView()
        case "dualPane":
          return dualPaneView()
        default:
          return listPreviewView(showPreview)
      }
    }
  ])
}

export async function openFinder(_args: Record<string, unknown> = {}, ctx?: CmuxCommandContext) {
  return ops.openPane(ctx?.gesture ?? null)
}

export async function addFolder() {
  await pickFolder()
  return {}
}

export async function connectHost() {
  await connect()
  return {}
}

export const cycleVariant = cycle
