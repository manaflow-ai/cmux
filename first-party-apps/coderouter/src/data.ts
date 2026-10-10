// The reads a surface needs, created inside its mount (so subscriptions end
// with it), and the onboarding facts derived from them.

import type { Account, ApiKey, Detected, Route, Status, Surface, Usage, UsageGroup, UsageWindow } from "./model.ts"
import type { Facts } from "./onboarding.ts"
import { CHANGED, DETECT_CHANGED, OP } from "./ops.ts"
import { idle, query, type Query } from "./query.ts"
import { lastTest } from "./store.ts"

export interface Core {
  status: Query<Status>
  detected: Query<Detected[]>
  accounts: Query<Account[]>
  keys: Query<ApiKey[]>
  facts: () => Facts
}

/** `light`: status only (the status item); the other reads stay empty and never call the host. */
export function core(light = false): Core {
  const status = query<Status>(OP.status)
  const detected = light ? idle<Detected[]>() : query<Detected[]>(OP.detect, () => ({}), [DETECT_CHANGED, CHANGED])
  const accounts = light ? idle<Account[]>() : query<Account[]>(OP.accounts)
  const keys = light ? idle<ApiKey[]>() : query<ApiKey[]>(OP.keys)
  const facts = computed<Facts>(() => factsOf(status(), accounts(), keys(), lastTest()?.ok === true))
  return { status, detected, accounts, keys, facts }
}

export function factsOf(status: Status | undefined, accounts: readonly Account[] | undefined, keys: readonly ApiKey[] | undefined, lastTestOk: boolean): Facts {
  const list = accounts ?? []
  return {
    signedIn: status?.signed_in === true,
    scopeKind: status?.scope?.kind ?? null,
    connected: list.length,
    privateConnected: list.filter((a) => a.visibility === "private" && a.mine).length,
    agentsRouted: status?.agents_routed === true,
    keys: (keys ?? []).filter((k) => !k.revoked).length,
    lastTestOk
  }
}

export interface Insights {
  usageWindow: () => UsageWindow
  setUsageWindow: (w: UsageWindow) => void
  usageGroup: () => UsageGroup
  setUsageGroup: (g: UsageGroup) => void
  usage: Query<Usage>
  surface: () => Surface
  setSurface: (s: Surface) => void
  route: Query<Route>
}

/** Usage and routing: only the dashboard reads them. */
export function insights(): Insights {
  const configured = cmux.app.settings().usageWindow
  const [usageWindow, setUsageWindow] = signal<UsageWindow>(configured === "24h" || configured === "30d" ? configured : "7d")
  const [usageGroup, setUsageGroup] = signal<UsageGroup>("account")
  const [surface, setSurface] = signal<Surface>("responses")
  const usage = query<Usage>(OP.usage, () => ({ window: usageWindow(), group_by: usageGroup() }))
  const route = query<Route>(OP.route, () => ({ surface: surface() }))
  return { usageWindow, setUsageWindow, usageGroup, setUsageGroup, usage, surface, setSurface, route }
}
