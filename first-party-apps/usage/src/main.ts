/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Usage: agent plan usage and limits (Claude Code and Codex plans, API
// budgets, CodeRouter pools) in the menu bar and a sidebar section, with
// warnings at thresholds. All numbers come from the host-side usage service
// (`usage.get`, `usage.changed`); the app never sees a credential.

import { statusJSON, type StatusArgs } from "./status.ts"
import { allAccounts, attach, load, problem, refreshNow, staleMs, state, thresholds } from "./store.ts"
import { cycleVariant as cycle, loadVariantOverride, variant } from "./variant.ts"
import { metersDetail, metersStatus } from "./views/meters.ts"
import { percentDetail, percentStatus } from "./views/percent.ts"
import { quietDetail, quietStatus } from "./views/quiet.ts"

const SECTION = "cmux/usage#usage"

/** Shows the usage section (the popover, once the platform has one: README gap 1). */
export async function show(): Promise<{ shown: boolean; reason?: string }> {
  try {
    await cmux.actions.run("sidebar.section.reveal", { contribution: SECTION })
    return { shown: true }
  } catch (e) {
    return { shown: false, reason: (e as { code?: string }).code ?? String(e) }
  }
}

export async function refresh(): Promise<{ requested: boolean; accounts: number }> {
  const r = await refreshNow()
  return { ...r, accounts: allAccounts().length }
}

export const cycleVariant = () => cycle()

/** Agents: `cmux apps run cmux/usage#status --args '{"provider":"codex"}'` or the MCP tool. */
export async function status(args: StatusArgs = {}) {
  if (args.refresh) await refreshNow(args.provider ? { provider: args.provider } : {})
  else await load()
  return statusJSON(allAccounts(), { now: Date.now(), staleMs: staleMs(), thresholds: thresholds(), state: state(), problem: problem(), provider: args.provider })
}

const actions = { refresh: () => refresh(), show: () => show() }

export function renderStatus() {
  loadVariantOverride()
  attach("glance")
  return HStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "menuMeters":
          return metersStatus(actions)
        case "sidebarOnly":
          return quietStatus(actions)
        default:
          return percentStatus(actions)
      }
    }
  ])
}

export function renderSection() {
  loadVariantOverride()
  attach("detail")
  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "menuMeters":
          return metersDetail()
        case "sidebarOnly":
          return quietDetail()
        default:
          return percentDetail()
      }
    }
  ])
}
