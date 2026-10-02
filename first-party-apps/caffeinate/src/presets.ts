// Presets and custom choices -> `power.assertion.create` params. Pure.

import { normalizeKinds, USER_ACTIVITY_DEFAULT_S, type Kind } from "./kinds.ts"
import { t } from "./l10n.ts"
import { durationWords } from "./format.ts"

export const PRESETS = ["command", "untilStopped", "hour", "duration"] as const
export type Preset = (typeof PRESETS)[number]
export const isPreset = (v: unknown): v is Preset => typeof v === "string" && (PRESETS as readonly string[]).includes(v)

/** Durations offered in the menu and the pane, in minutes. */
export const DURATIONS = [15, 30, 60, 120, 240, 480] as const
/** The host refuses timed assertions longer than this (README "Limits"); the app checks first. */
export const MAX_MINUTES = 24 * 60

/**
 * Default kinds per preset. A running command needs the Mac awake, not the
 * display (`caffeinate` with no option does the same); the others are for a
 * person at the Mac, so the display stays on too.
 */
export const DEFAULT_KINDS: Record<Preset, Kind[]> = {
  command: ["idle"],
  untilStopped: ["display", "idle"],
  hour: ["display", "idle"],
  duration: ["display", "idle"]
}

export type StartOptions = {
  kinds?: unknown
  minutes?: unknown
  terminal?: unknown
  task?: unknown
  pid?: unknown
  /** Display text for the terminal or task ("cargo · api"); the host may replace it. */
  label?: unknown
  reason?: unknown
}

export type CreateParams = {
  kinds: Kind[]
  reason: string
  timeout_s?: number
  until?: { terminal: string; end: "command" } | { task: string } | { pid: number }
  until_label?: string
}

export type PresetResult = { ok: true; params: CreateParams } | { ok: false; code: string; message: string }

const fail = (code: string, message: string): PresetResult => ({ ok: false, code, message })
const handle = (v: unknown, prefix: string) => (typeof v === "string" && v.startsWith(prefix) && v.length > prefix.length ? v : null)

function minutesOf(v: unknown): number | null {
  const n = typeof v === "string" && v.trim() ? Number(v.trim()) : v
  return typeof n === "number" && Number.isFinite(n) ? Math.round(n) : null
}

export function presetRequest(preset: Preset, options: StartOptions = {}): PresetResult {
  const kinds = options.kinds === undefined ? DEFAULT_KINDS[preset] : normalizeKinds(options.kinds)
  if (!kinds.length) return fail("caffeinate.no_kinds", t("error.noKinds", "Choose at least one thing to keep awake."))
  const params: CreateParams = { kinds, reason: "" }
  let title: string
  switch (preset) {
    case "command": {
      // A terminal handle ends exactly with its command; a raw pid can be reused, so it is the last choice.
      const terminal = handle(options.terminal, "terminal_")
      const task = handle(options.task, "task_")
      const pid = minutesOf(options.pid)
      if (terminal) params.until = { terminal, end: "command" }
      else if (task) params.until = { task }
      else if (pid !== null && pid > 0) params.until = { pid }
      else return fail("caffeinate.no_handle", t("error.noHandle", "Choose the terminal whose command keeps the Mac awake."))
      if (typeof options.label === "string" && options.label) params.until_label = options.label
      title = t("title.while", "While {what} runs", { what: params.until_label ?? ("pid" in params.until ? t("until.pid", "process {pid}", { pid: params.until.pid }) : t("until.terminal", "the command")) })
      const minutes = minutesOf(options.minutes)
      if (minutes !== null) {
        const err = checkMinutes(minutes)
        if (err) return err
        params.timeout_s = minutes * 60
      }
      break
    }
    case "untilStopped":
      title = t("title.untilStopped", "Until stopped")
      break
    case "hour":
      params.timeout_s = 3600
      title = t("title.for", "For {duration}", { duration: durationWords(60) })
      break
    case "duration": {
      const minutes = minutesOf(options.minutes)
      if (minutes === null) return fail("caffeinate.no_duration", t("error.noDuration", "Enter a number of minutes."))
      const err = checkMinutes(minutes)
      if (err) return err
      params.timeout_s = minutes * 60
      title = t("title.for", "For {duration}", { duration: durationWords(minutes) })
      break
    }
  }
  // `caffeinate -u` without a time declares activity for 5 seconds; keep that meaning when it is the only kind.
  if (params.timeout_s === undefined && !params.until && kinds.length === 1 && kinds[0] === "user") params.timeout_s = USER_ACTIVITY_DEFAULT_S
  params.reason = typeof options.reason === "string" && options.reason.trim() ? options.reason.trim().slice(0, 120) : t("reason.default", "cmux Caffeinate: {title}", { title })
  return { ok: true, params }
}

function checkMinutes(minutes: number): PresetResult | null {
  if (minutes < 1) return fail("caffeinate.bad_duration", t("error.shortDuration", "Choose at least 1 minute."))
  if (minutes > MAX_MINUTES) return fail("caffeinate.bad_duration", t("error.longDuration", "Choose at most 24 hours, or Until Stopped."))
  return null
}
