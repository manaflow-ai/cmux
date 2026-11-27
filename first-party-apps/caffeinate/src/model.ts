// The proposed host capability's wire shapes (README "Power assertions") and
// the app's state, built from `power.assertion.list` and the stream
// `power.assertion.watch`. Pure: no cmux calls.

import { normalizeKinds, type Kind } from "./kinds.ts"

export type Origin = "user" | "script" | "agent"

/** What ends an assertion besides its timeout: a terminal's command, a task, or a process. */
export type Until = { terminal?: string; task?: string; pid?: number; end?: "command" | "close" }

export type Assertion = {
  id: string
  kinds: Kind[]
  reason: string
  createdAt: number
  expiresAt: number | null
  until: Until | null
  /** The host's display text for the handle ("cargo · api"). */
  untilLabel: string | null
  owner: { actor: string; origin: Origin; app: string | null }
  /** Kinds the host could not hold right now (system on battery). */
  inactive: Kind[]
}

export type PowerSource = "ac" | "battery" | "unknown"
export type ReleaseCause = "user" | "timeout" | "until" | "owner_disabled" | "owner_uninstalled" | "host_restart" | "replaced"

export type PowerState = {
  revision: bigint
  available: boolean
  /** Why the host cannot hold assertions (`power.unsupported_platform`), when not available. */
  unavailableReason: string | null
  powerSource: PowerSource
  assertions: Assertion[]
  /** The last release the user did not ask for, for one notice line. */
  lastRelease: { id: string; cause: ReleaseCause; title: string } | null
}

export const emptyState = (): PowerState => ({ revision: -1n, available: true, unavailableReason: null, powerSource: "unknown", assertions: [], lastRelease: null })

const time = (v: unknown): number | null => {
  if (typeof v === "number" && Number.isFinite(v)) return v
  if (typeof v === "string" && v) {
    const n = /^\d+$/.test(v) ? Number(v) : Date.parse(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

const revisionOf = (v: unknown): bigint | null => {
  if (typeof v === "string" && /^\d+$/.test(v)) return BigInt(v)
  if (typeof v === "number" && Number.isInteger(v) && v >= 0) return BigInt(v)
  return null
}

function normalizeUntil(raw: unknown): Until | null {
  if (!raw || typeof raw !== "object") return null
  const r = raw as Record<string, unknown>
  const out: Until = {}
  if (typeof r.terminal === "string") out.terminal = r.terminal
  if (typeof r.task === "string") out.task = r.task
  if (typeof r.pid === "number" && Number.isInteger(r.pid) && r.pid > 0) out.pid = r.pid
  if (r.end === "command" || r.end === "close") out.end = r.end
  return out.terminal || out.task || out.pid ? out : null
}

const ORIGINS: readonly Origin[] = ["user", "script", "agent"]

/** One assertion record from the host, or null when it is not one. */
export function normalizeAssertion(raw: unknown): Assertion | null {
  if (!raw || typeof raw !== "object") return null
  const r = raw as Record<string, unknown>
  const id = typeof r.assertion === "string" ? r.assertion : typeof r.id === "string" ? r.id : null
  if (!id) return null
  const kinds = normalizeKinds(r.kinds)
  if (!kinds.length) return null
  const owner = (r.owner ?? {}) as Record<string, unknown>
  return {
    id,
    kinds,
    reason: typeof r.reason === "string" ? r.reason : "",
    createdAt: time(r.created_at) ?? 0,
    expiresAt: time(r.expires_at),
    until: normalizeUntil(r.until),
    untilLabel: typeof r.until_label === "string" && r.until_label ? r.until_label : null,
    owner: {
      actor: typeof owner.actor === "string" ? owner.actor : "",
      origin: ORIGINS.includes(owner.origin as Origin) ? (owner.origin as Origin) : "script",
      app: typeof owner.app === "string" ? owner.app : null
    },
    inactive: normalizeKinds(r.inactive_kinds)
  }
}

const sortAssertions = (list: Assertion[]) =>
  // Soonest end first; untimed ones after, newest first.
  list.slice().sort((a, b) => (a.expiresAt ?? Infinity) - (b.expiresAt ?? Infinity) || b.createdAt - a.createdAt || a.id.localeCompare(b.id))

const POWER_SOURCES: readonly PowerSource[] = ["ac", "battery", "unknown"]

/** State from a `power.assertion.list` result. */
export function fromList(raw: unknown, previous: PowerState = emptyState()): PowerState {
  const r = (raw ?? {}) as Record<string, unknown>
  const list = Array.isArray(r.assertions) ? r.assertions : []
  return {
    revision: revisionOf(r.revision) ?? previous.revision,
    available: r.available !== false,
    unavailableReason: r.available === false && typeof r.unavailable_reason === "string" ? r.unavailable_reason : null,
    powerSource: POWER_SOURCES.includes(r.power_source as PowerSource) ? (r.power_source as PowerSource) : "unknown",
    assertions: sortAssertions(list.map(normalizeAssertion).filter((a): a is Assertion => a !== null)),
    lastRelease: previous.lastRelease
  }
}

/**
 * Applies one `power.assertion.watch` event. Events at or below the current
 * revision are ignored (the list read already covers them), so a list read and
 * the stream may race without double effects. `title` names an assertion for
 * the release notice.
 */
export function applyEvent(state: PowerState, raw: unknown, title: (a: Assertion) => string = (a) => a.id): PowerState {
  if (!raw || typeof raw !== "object") return state
  const e = raw as Record<string, unknown>
  const revision = revisionOf(e.revision)
  if (revision === null || revision <= state.revision) return state
  switch (e.type) {
    case "reset":
      return { ...fromList(e, state), revision }
    case "created":
    case "updated": {
      const a = normalizeAssertion(e.assertion)
      if (!a) return { ...state, revision }
      return { ...state, revision, assertions: sortAssertions([...state.assertions.filter((x) => x.id !== a.id), a]) }
    }
    case "released": {
      const id = typeof e.assertion === "string" ? e.assertion : null
      const gone = state.assertions.find((x) => x.id === id)
      const cause = (typeof e.cause === "string" ? e.cause : "user") as ReleaseCause
      return {
        ...state,
        revision,
        assertions: state.assertions.filter((x) => x.id !== id),
        // The user knows what they stopped; tell them only about the others.
        lastRelease: gone && cause !== "user" ? { id: gone.id, cause, title: title(gone) } : state.lastRelease
      }
    }
    case "power":
      return {
        ...state,
        revision,
        powerSource: POWER_SOURCES.includes(e.power_source as PowerSource) ? (e.power_source as PowerSource) : state.powerSource,
        available: typeof e.available === "boolean" ? e.available : state.available,
        assertions: Array.isArray(e.inactive) ? state.assertions.map((a) => ({ ...a, inactive: normalizeKinds((e.inactive as Record<string, unknown>[]).find((x) => x?.assertion === a.id)?.kinds) })) : state.assertions
      }
    default:
      return { ...state, revision }
  }
}

/** Assertions still running at `now` (the host's release event may lag the timeout by a moment). */
export const running = (state: PowerState, now: number) => state.assertions.filter((a) => a.expiresAt === null || a.expiresAt > now)

/** The soonest end among timed assertions, or null. */
export const soonestEnd = (list: readonly Assertion[]) => list.reduce<number | null>((m, a) => (a.expiresAt === null ? m : m === null ? a.expiresAt : Math.min(m, a.expiresAt)), null)
