// Relative ages and snooze presets, in local time, without Intl (QuickJS
// builds may lack it).

import { t } from "./l10n.ts"

/** Compact age: "now", "5m", "3h", "2d", "4w". */
export function ago(at: number, now: number): string {
  const minutes = Math.floor(Math.max(0, now - at) / 60_000)
  if (minutes < 1) return t("ago.now", "now")
  if (minutes < 60) return t("ago.m", "{n}m", { n: minutes })
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return t("ago.h", "{n}h", { n: hours })
  const days = Math.floor(hours / 24)
  if (days < 7) return t("ago.d", "{n}d", { n: days })
  return t("ago.w", "{n}w", { n: Math.floor(days / 7) })
}

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const hhmm = (d: Date) => `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`
const sameDay = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()

/** "14:30" today, "Tomorrow 9:00", else "Mon 9:00". */
export function clock(until: number, now: number): string {
  const d = new Date(until)
  const n = new Date(now)
  if (sameDay(d, n)) return hhmm(d)
  const tomorrow = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1)
  if (sameDay(d, tomorrow)) return t("time.tomorrow", "Tomorrow {time}", { time: hhmm(d) })
  const day = d.getDay()
  return t("time.weekday", "{day} {time}", { day: t(`day.${day}`, DAYS[day]!), time: hhmm(d) })
}

export interface SnoozePreset {
  id: "30m" | "2h" | "tomorrow" | "nextWeek"
  until: number
  label: string
}

const MORNING_HOUR = 9

/** Presets with their absolute wake time in the label ("In 2 hours (16:30)"). */
export function snoozePresets(now: number): SnoozePreset[] {
  const n = new Date(now)
  const tomorrow = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1, MORNING_HOUR).getTime()
  // Next Monday (a week from today when today is Monday).
  const daysToMonday = ((8 - n.getDay()) % 7) || 7
  const nextWeek = new Date(n.getFullYear(), n.getMonth(), n.getDate() + daysToMonday, MORNING_HOUR).getTime()
  const presets: Array<[SnoozePreset["id"], number, string]> = [
    ["30m", now + 30 * 60_000, "In 30 minutes ({time})"],
    ["2h", now + 2 * 3_600_000, "In 2 hours ({time})"],
    ["tomorrow", tomorrow, "Tomorrow ({time})"],
    ["nextWeek", nextWeek, "Next week ({time})"]
  ]
  return presets.map(([id, until, english]) => ({ id, until, label: t(`snooze.${id}`, english, { time: id === "tomorrow" ? hhmm(new Date(until)) : clock(until, now) }) }))
}
