// What can be kept awake, in plain words. Each kind is one IOKit power
// assertion the host takes for the app; the flag is the matching option of
// the macOS `caffeinate` tool, shown for people who know it.

import { t } from "./l10n.ts"

export const KINDS = ["display", "idle", "disk", "system", "user"] as const
export type Kind = (typeof KINDS)[number]

export const isKind = (v: unknown): v is Kind => typeof v === "string" && (KINDS as readonly string[]).includes(v)

/** The `caffeinate` option with the same effect. */
export const FLAG: Record<Kind, string> = { display: "-d", idle: "-i", disk: "-m", system: "-s", user: "-u" }

/** A user-activity declaration lasts this long when no time is set (as `caffeinate -u`). */
export const USER_ACTIVITY_DEFAULT_S = 5

export const SYMBOL: Record<Kind, string> = {
  display: "display",
  idle: "moon.zzz",
  disk: "internaldrive",
  system: "powerplug",
  user: "hand.wave"
}

export function kindTitle(kind: Kind): string {
  switch (kind) {
    case "display":
      return t("kind.display", "Display")
    case "idle":
      return t("kind.idle", "Mac")
    case "disk":
      return t("kind.disk", "Disks")
    case "system":
      return t("kind.system", "Mac on AC power")
    case "user":
      return t("kind.user", "Wake display")
  }
}

export function kindExplanation(kind: Kind): string {
  switch (kind) {
    case "display":
      return t("kind.display.explain", "The display stays on.")
    case "idle":
      return t("kind.idle.explain", "The Mac does not sleep when idle. The display can still turn off.")
    case "disk":
      return t("kind.disk.explain", "Disks do not sleep when idle.")
    case "system":
      return t("kind.system.explain", "The Mac does not sleep at all while on power. On battery this does nothing.")
    case "user":
      return t("kind.user.explain", "Tells the Mac you are active: the display wakes. Lasts 5 seconds unless you set a time.")
  }
}

/** "display, Mac": the kinds in canonical order, as short words. */
export function kindsText(kinds: readonly Kind[]): string {
  return KINDS.filter((k) => kinds.includes(k))
    .map(kindTitle)
    .join(t("list.separator", ", "))
}

/** Canonical order, no duplicates, unknown values dropped. */
export function normalizeKinds(raw: unknown): Kind[] {
  const list = Array.isArray(raw) ? raw : []
  return KINDS.filter((k) => list.includes(k))
}
