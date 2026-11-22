/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Usage: every AI plan account the user's routers know (Claude, Codex and
// the other providers), with session and weekly headroom, resets and a pace
// verdict per provider, in the menu bar, a pane and a sidebar section. All
// numbers come from the app's usage server (`account.list`, `account.usage`,
// event `account.watch`); the app never runs the router and never polls.

import { statusJSON, type StatusArgs } from "./status.ts"
import { load, paces, problem, refreshNow, staleMs, state, attach, usage } from "./store.ts"
import { cycleVariant as cycle, loadVariantOverride, variant } from "./variant.ts"
import { metersPane, metersSection, metersStatus } from "./views/meters.ts"
import { quietPane, quietSection, quietStatus } from "./views/quiet.ts"
import { rowsPane, rowsSection, rowsStatus } from "./views/rows.ts"

const PANE = "cmux/usage#usagePane"

/** Opens the usage pane (proposed action `app.pane.open`: README "Proposed operations"). */
export async function show(): Promise<{ shown: boolean; reason?: string }> {
  try {
    await cmux.actions.run("app.pane.open", { kind: PANE })
    return { shown: true }
  } catch (e) {
    return { shown: false, reason: (e as { code?: string }).code ?? String(e) }
  }
}

export async function refresh(): Promise<{ requested: boolean; providers: number }> {
  const r = await refreshNow()
  return { ...r, providers: usage()?.providers.length ?? 0 }
}

export const cycleVariant = () => cycle()

/** Agents: `cmux apps run cmux/usage#status --args '{"provider":"claude"}'` or the MCP tool. */
export async function status(args: StatusArgs = {}) {
  if (args.refresh) await refreshNow()
  else await load()
  return statusJSON(usage(), paces(), { now: Date.now(), staleMs: staleMs(), state: state(), problem: problem(), provider: args.provider, accounts: args.accounts === true })
}

const actions = { refresh: () => refresh(), show: () => show() }

export function renderStatus() {
  loadVariantOverride()
  attach("glance")
  return HStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "meters":
          return metersStatus(actions)
        case "quiet":
          return quietStatus(actions)
        default:
          return rowsStatus(actions)
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
        case "meters":
          return metersSection(actions)
        case "quiet":
          return quietSection(actions)
        default:
          return rowsSection(actions)
      }
    }
  ])
}

export function renderPane() {
  loadVariantOverride()
  attach("detail")
  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "meters":
          return metersPane()
        case "quiet":
          return quietPane()
        default:
          return rowsPane()
      }
    }
  ])
}
