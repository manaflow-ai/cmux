/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Search: one place to find anything in cmux (workspaces, terminals and their
// text, browser tabs and history, other apps' items, files) and open it.
// Exports: the sidebar section, the pane kind, and the commands.

import { runSearch } from "./engine.ts"
import { setLocale } from "./l10n.ts"
import { clearMemory, currentVariant, loadMemory, opened, storeVariant } from "./memory.ts"
import { effectiveSources, isSourceId, parseQuery, type SourceId } from "./query.ts"
import { nextVariant, settings } from "./settings.ts"
import { toAgentResult } from "./agent.ts"
import { createController, type Density } from "./ui/controller.ts"
import { GroupedView } from "./ui/grouped.ts"
import { PaletteView } from "./ui/palette.ts"
import { PreviewView } from "./ui/preview.ts"

interface RenderContext {
  contribution?: string
  surface?: string
  locale?: string
}

const hostLocale = (ctx: RenderContext) => ctx.locale ?? (globalThis as { navigator?: { language?: string } }).navigator?.language ?? "en"

function render(ctx: RenderContext, density: Density) {
  setLocale(hostLocale(ctx))
  const c = createController(density, ctx)
  return VStack({ spacing: 0 }, [
    () => {
      switch (currentVariant()) {
        case "preview":
          return PreviewView(c, density)
        case "palette":
          return PaletteView(c, density)
        default:
          return GroupedView(c)
      }
    }
  ])
}

/** Sidebar section `search`. */
export function renderSection(ctx: RenderContext = {}) {
  return render(ctx, "compact")
}

/** Pane kind `search` (the platform does not mount pane kinds yet; the preview harness renders it). */
export function renderPane(ctx: RenderContext = {}) {
  return render(ctx, "full")
}

interface SearchArgs {
  query?: string
  sources?: string[]
  limit?: number
  scope?: "workspace" | "all"
  regex?: boolean
}

/**
 * Command `search` (palette, keybinding, CLI `cmux apps run cmux/search#search`,
 * MCP tool). Runs as automation: it never moves focus. Each result carries the
 * op that opens it, so an agent can call that op itself.
 */
export async function search(args: SearchArgs = {}) {
  await loadMemory()
  const query = parseQuery(String(args.query ?? ""), { regex: args.regex === true })
  const wanted = Array.isArray(args.sources) ? args.sources.filter(isSourceId) : null
  const sources = effectiveSources(query, null, settings().sources).filter((s: SourceId) => !wanted || wanted.includes(s))
  const limit = Math.max(1, Math.min(200, Math.floor(Number(args.limit ?? 20)) || 20))
  const scope = query.scope ?? args.scope ?? settings().defaultScope
  const response = await runSearch(
    { query, sources, scope, density: "full", limit, searchId: "command", opened: opened(), selfId: cmux.app.id, nowMs: Date.now() },
    (op, params) => cmux.call(op, params)
  )
  return toAgentResult(response, limit)
}

/** Command `cycleVariant` ("Next Search Variant", DEV/NIGHTLY). */
export async function cycleVariant() {
  await loadMemory()
  const next = nextVariant(currentVariant())
  storeVariant(next)
  return { variant: next }
}

/** Command `clearRecent`. */
export async function clearRecent() {
  await clearMemory()
  return { cleared: true }
}
