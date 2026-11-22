// Who may start and stop what. The host enforces these rules on
// `power.assertion.create` and `.release` (README "Power assertions"); the app
// checks them first when a command tells it who invoked it, so an agent gets a
// clear refusal instead of a host error. Pure.

import { t } from "./l10n.ts"
import type { Assertion, Origin } from "./model.ts"
import type { CreateParams } from "./presets.ts"

/** The principal behind a command: proposed `ctx.invoker` (README gap 3). */
export type Invoker = { actor: string; origin: Origin; terminal?: string | null }

export type Refusal = { code: "power.not_permitted"; message: string }

const refuse = (message: string): Refusal => ({ code: "power.not_permitted", message })

/** Longest time limit an agent or script may set (README "Power assertions"). */
export const AGENT_MAX_TIMEOUT_S = 4 * 3600

/** A person may start anything; an agent or script only an assertion bound to its own terminal, capped at 4 hours. */
export function checkCreate(invoker: Invoker | null, params: CreateParams): Refusal | null {
  if (!invoker || invoker.origin === "user") return null
  const until = params.until
  if (!until || !("terminal" in until)) return refuse(t("policy.agentBound", "Agents can keep the Mac awake only while their own terminal's command runs."))
  if (!invoker.terminal || until.terminal !== invoker.terminal) return refuse(t("policy.agentOwnTerminal", "Agents can bind only to their own terminal."))
  if (params.timeout_s !== undefined && params.timeout_s > AGENT_MAX_TIMEOUT_S) return refuse(t("policy.agentMaxTime", "Agents can set at most 4 hours."))
  return null
}

/** A person may stop anything; others only what they started. */
export function checkRelease(invoker: Invoker | null, assertion: Assertion): Refusal | null {
  if (!invoker || invoker.origin === "user") return null
  if (assertion.owner.actor && assertion.owner.actor === invoker.actor) return null
  return refuse(t("policy.othersNeedUser", "Only you can stop what someone else started."))
}

/** Reads the proposed `ctx.invoker` of a command; null when the host does not send it yet. */
export function invokerOf(ctx: unknown): Invoker | null {
  const inv = (ctx as { invoker?: Record<string, unknown> } | null)?.invoker
  if (!inv || typeof inv.actor !== "string") return null
  const origin = inv.origin === "user" || inv.origin === "agent" ? inv.origin : "script"
  return { actor: inv.actor, origin, terminal: typeof inv.terminal === "string" ? inv.terminal : null }
}
