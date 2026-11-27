/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Caffeinate: keep the Mac awake, with the macOS `caffeinate` options
// explained in plain words. Presets: until stopped, for a time, or while a
// terminal's command runs. The app never spawns a process: it asks the host
// for IOKit power assertions through the proposed `power.assertion.*` ops and
// follows `power.assertion.watch` (README "Power assertions").

import { assertionTitle, timeLeftText } from "./format.ts"
import { FLAG } from "./kinds.ts"
import { checkCreate, checkRelease, invokerOf } from "./policy.ts"
import { isPreset, presetRequest, type Preset, type StartOptions } from "./presets.ts"
import { active, attach, create, load, power, release, releaseAll, status, type StartResult } from "./store.ts"
import { ensureTerminals } from "./terminals.ts"
import { cycleVariant as cycle, loadVariantOverride, variant } from "./variant.ts"
import { menuPane, menuStatus } from "./views/menu.ts"
import { panePane, paneStatus } from "./views/pane.ts"

const PANE = "cmux/caffeinate#caffeinatePane"

type CommandCtx = { gesture?: string; invoker?: unknown } | undefined

/** Opens the pane (proposed action `app.pane.open`). */
export async function show(_args: Record<string, unknown> = {}, ctx?: CommandCtx & { cmux?: CmuxGlobal }): Promise<{ shown: boolean; reason?: string }> {
  try {
    await (ctx?.cmux ?? cmux).actions.run("app.pane.open", { kind: PANE, gesture: ctx?.gesture ?? undefined })
    return { shown: true }
  } catch (e) {
    return { shown: false, reason: (e as { code?: string }).code ?? String(e) }
  }
}

const actions = { show: () => void show() }

type StartArgs = StartOptions & { preset?: string; request_id?: string }

const presetOf = (args: StartArgs): Preset => {
  if (isPreset(args.preset)) return args.preset
  if (args.terminal || args.task || args.pid) return "command"
  return args.minutes === undefined ? "untilStopped" : "duration"
}

/**
 * `cmux apps run cmux/caffeinate#start --args '{"preset":"hour"}'`, the MCP
 * tool, and the palette commands below. Agents may only bind to their own
 * terminal: `{"preset":"command","terminal":"terminal_…"}`.
 */
export async function start(args: StartArgs = {}, ctx?: CommandCtx): Promise<StartResult> {
  const r = presetRequest(presetOf(args), args)
  if (!r.ok) return { started: false, code: r.code, message: r.message }
  const refusal = checkCreate(invokerOf(ctx), r.params)
  if (refusal) return { started: false, ...refusal }
  return create(r.params, { gesture: ctx?.gesture, idempotencyKey: typeof args.request_id === "string" ? `start:${args.request_id}` : undefined })
}

export const keepAwake = (_args: unknown, ctx?: CommandCtx) => start({ preset: "untilStopped" }, ctx)
export const keepAwakeHour = (_args: unknown, ctx?: CommandCtx) => start({ preset: "hour" }, ctx)

export async function stop(args: { assertion?: string } = {}, ctx?: CommandCtx) {
  if (typeof args.assertion !== "string") return { released: false, code: "caffeinate.no_assertion" }
  if (status() === "loading") await load()
  const target = power().assertions.find((a) => a.id === args.assertion)
  const refusal = target ? checkRelease(invokerOf(ctx), target) : null
  if (refusal) return { released: false, ...refusal }
  return release(args.assertion, { gesture: ctx?.gesture })
}

export const stopAll = (_args: unknown, ctx?: CommandCtx) => releaseAll({ gesture: ctx?.gesture })

/** JSON for agents and the CLI. */
export async function list() {
  await load()
  const at = Date.now()
  const s = power()
  return {
    available: status() === "ready",
    state: status(),
    power_source: s.powerSource,
    assertions: active().map((a) => ({
      assertion: a.id,
      title: assertionTitle(a),
      kinds: a.kinds,
      flags: a.kinds.map((k) => FLAG[k]).join(" "),
      expires_at: a.expiresAt === null ? null : new Date(a.expiresAt).toISOString(),
      time_left: a.expiresAt === null ? null : timeLeftText(a.expiresAt - at),
      until: a.until,
      until_label: a.untilLabel,
      owner: a.owner
    }))
  }
}

export const cycleVariant = () => cycle()

export function renderStatus() {
  loadVariantOverride()
  attach()
  return HStack({ spacing: 0 }, [
    () => {
      if (variant() === "pane") return paneStatus(actions)
      // The dropdown lists running commands; read them once, then on Refresh.
      ensureTerminals()
      return menuStatus(actions)
    }
  ])
}

export function renderPane() {
  loadVariantOverride()
  attach()
  return VStack({ spacing: 0 }, [() => (variant() === "pane" ? panePane() : menuPane())])
}
