// The one warning: a provider has accounts but none is usable (all used up,
// cooling or failing). Sent once, re-armed when an account is usable again.
// Pure planning; the store sends the notification and keeps `Fired` in
// cmux.storage so an app restart does not repeat it.
//
// Per-account limit warnings are left out on purpose: with dozens of pooled
// accounts the router switches accounts long before the user could act.

import type { Provider } from "./model.ts"

/** Providers that already warned. */
export type Fired = Record<string, true>

export interface Alert {
  provider: string
  total: number
}

export function planAlerts(providers: readonly Provider[], fired: Fired): { alerts: Alert[]; fired: Fired } {
  const next: Fired = {}
  const alerts: Alert[] = []
  const seen = new Set<string>()
  for (const p of providers) {
    seen.add(p.id)
    const out = p.summary.total > 0 && p.summary.usable === 0
    if (!out) continue
    next[p.id] = true
    if (!fired[p.id]) alerts.push({ provider: p.id, total: p.summary.total })
  }
  // A provider missing from this reading keeps its state, so a router hiccup does not re-warn.
  for (const id of Object.keys(fired)) if (!seen.has(id)) next[id] = true
  return { alerts, fired: next }
}
