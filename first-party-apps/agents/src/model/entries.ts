// What the owner reports for one CLI on one machine (agent_cli.list), how a
// watch event changes it, and the status a row shows. Pure functions.

import type { InstallMethod } from "./providers.ts"
import { PROVIDERS, providerFor, providerRank, signsInItself } from "./providers.ts"
import { updateLevel, type UpdateLevel } from "./version.ts"

export type AccountStatus = "signed_in" | "expired" | "missing" | "unknown"

/** A sign-in the CLI holds. `label` is a non-secret name the owner chose or the user set ("Work"); never an email or a token. */
export type Account = { account: string; label: string; plan?: string | null; status: AccountStatus }

export type CliEntry = {
  cli: string
  /** Owner display name for CLIs the app table does not know. */
  name?: string | null
  /** Null when the owner has not established that the agent itself is installed. */
  installed: boolean | null
  version: string | null
  latest: { version: string; checked_at?: number | null } | null
  install_method: InstallMethod | null
  /** The owner can run an update command for this install method. */
  updatable: boolean
  /** Where the binary is, for display only ("~/.local/bin/claude"). */
  path_label?: string | null
  accounts: Account[]
  /** Presence-only sign-in evidence when the owner has no account labels. */
  auth_status?: AccountStatus
}

export type Machine = {
  id: string
  name: string
  origin: string
  status: string
  os?: string | null
  platform?: { os?: string | null; arch?: string | null } | null
  capabilities?: string[]
}

const CAPABILITY_NAME = /^[a-z][a-z0-9_.-]{0,63}$/
const MACHINE_TOKEN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

/** Validate wire values before formatting them or admitting them to state. */
function capabilityNames(value: unknown, limit: number): string[] {
  if (!Array.isArray(value)) return []
  const names = new Set<string>()
  for (const name of value) {
    if (typeof name !== "string" || !CAPABILITY_NAME.test(name)) continue
    names.add(name)
    if (names.size === limit) break
  }
  return [...names]
}

/** A bounded, non-secret capability summary suitable for a machine header. */
export function capabilitySummary(machine: Pick<Machine, "capabilities">): string | null {
  const names = capabilityNames(machine.capabilities, 8)
  return names.length ? names.map((name) => name.replaceAll("_", " ")).join(" · ") : null
}

/** Normalize owner-provided machine metadata before it enters app state. */
export function sanitizeMachine(machine: Machine): Machine {
  const rawPlatform = machine.platform && typeof machine.platform === "object" ? machine.platform : null
  const os = typeof rawPlatform?.os === "string" && MACHINE_TOKEN.test(rawPlatform.os) ? rawPlatform.os : null
  const arch = typeof rawPlatform?.arch === "string" && MACHINE_TOKEN.test(rawPlatform.arch) ? rawPlatform.arch : null
  const capabilities = capabilityNames(machine.capabilities, 16)
  return { ...machine, platform: os || arch ? { os, arch } : null, capabilities }
}

export type Status = "missing" | "current" | "update" | "ahead" | "unknown"

export function statusOf(e: CliEntry): Status {
  if (e.installed === false) return "missing"
  if (e.installed !== true) return "unknown"
  const level = updateLevel(e.version, e.latest?.version)
  if (level === "none") return "current"
  if (level === "newer") return "ahead"
  if (level === "unknown") return "unknown"
  return "update"
}

export const levelOf = (e: CliEntry): UpdateLevel => updateLevel(e.version, e.latest?.version)

const LEVEL_ORDER: UpdateLevel[] = ["major", "minor", "patch"]

/** The largest pending update among entries (one CLI on several machines), or null. */
export function highestLevel(list: readonly (CliEntry | null | undefined)[]): UpdateLevel | null {
  let best: UpdateLevel | null = null
  for (const e of list) {
    if (!e || statusOf(e) !== "update") continue
    const l = levelOf(e)
    if (best === null || LEVEL_ORDER.indexOf(l) < LEVEL_ORDER.indexOf(best)) best = l
  }
  return best
}

/** Installed first (table order), then missing (table order); unknown ids by name. */
export function sortEntries(list: readonly CliEntry[]): CliEntry[] {
  return [...list].sort((a, b) => {
    const rank = (e: CliEntry) => e.installed === true ? 0 : e.installed === false ? 2 : 1
    if (rank(a) !== rank(b)) return rank(a) - rank(b)
    const r = providerRank(a.cli) - providerRank(b.cli)
    return r || a.cli.localeCompare(b.cli)
  })
}

/** Only an explicitly complete inventory establishes that an unreported CLI is missing. */
export function withMissing(list: readonly CliEntry[], complete = false): CliEntry[] {
  if (complete !== true) return sortEntries(list)
  const seen = new Set(list.map((e) => e.cli))
  const missing = PROVIDERS.filter((p) => !seen.has(p.id)).map((p): CliEntry => ({ cli: p.id, installed: false, version: null, latest: null, install_method: null, updatable: false, accounts: [] }))
  return sortEntries([...list, ...missing])
}

/** The account whose state matters most: expired, then missing, then signed in. */
export function worstAccount(accounts: readonly Account[]): Account | null {
  const order: AccountStatus[] = ["expired", "missing", "unknown", "signed_in"]
  return [...accounts].sort((a, b) => order.indexOf(a.status) - order.indexOf(b.status))[0] ?? null
}

/** An installed CLI with explicit expired or signed-out evidence. No observation means unknown. */
export function needsSignIn(e: CliEntry): boolean {
  if (e.installed !== true) return false
  if (e.accounts.some((a) => a.status === "expired" || a.status === "missing")) return true
  return e.auth_status === "expired" || e.auth_status === "missing"
}

/** Whether the row shows account lines at all. */
export const showsAccounts = (e: CliEntry) => e.installed === true && (e.accounts.length > 0 || !!e.auth_status || (signsInItself(e.cli) && providerFor(e.cli) !== null))

const EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]+/g
const TOKENISH = /\b[A-Za-z0-9_-]{32,}\b/g

/**
 * Defense in depth: the owner must send only non-secret labels, but a label
 * that looks like an email or a long token is masked before it renders.
 */
export function safeLabel(label: string | null | undefined): string {
  return String(label ?? "")
    .replace(EMAIL, (m) => `${m[0]}…@…`)
    .replace(TOKENISH, "…")
    .trim()
}

/** Proposed owner-observation delta; the current store re-reads and never trusts event rows. */
export type WatchEvent = { machine: string; cli: string; entry?: CliEntry | null; removed?: boolean }

export function applyWatch(list: readonly CliEntry[], ev: WatchEvent, complete = false): CliEntry[] {
  // A removed table CLI turns back into a "not installed" entry.
  if (ev.removed) return withMissing(list.filter((e) => e.cli !== ev.cli), complete)
  if (!ev.entry) return [...list]
  const next = list.some((e) => e.cli === ev.cli) ? list.map((e) => (e.cli === ev.cli ? ev.entry! : e)) : [...list, ev.entry]
  return sortEntries(next)
}

export type Summary = { updates: number; missingSignIns: number; installed: number; unknown: number }

export function summarize(lists: readonly (readonly CliEntry[])[]): Summary {
  let updates = 0, missingSignIns = 0, installed = 0, unknown = 0
  for (const list of lists)
    for (const e of list) {
      if (statusOf(e) === "unknown") unknown++
      if (e.installed !== true) continue
      installed++
      if (statusOf(e) === "update") updates++
      if (needsSignIn(e)) missingSignIns++
    }
  return { updates, missingSignIns, installed, unknown }
}
