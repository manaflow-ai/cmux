/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// App settings (config layer, `cmux.json` apps."cmux/notes".settings) with the
// defaults from the manifest schema.

import type { SortOrder } from "./notes.ts"

export const VARIANTS = ["scratchpad", "list", "editor"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "scratchpad"
export const DEFAULT_BODY_LINES = 12
/** Lines one note may render inline even when expanded (the scene allows 4096 nodes per mount). */
export const MAX_RENDERED_LINES = 400

const setting = (key: string): unknown => cmux.app.settings()[key]

export const variant = (): Variant => {
  const v = setting("variant")
  return (VARIANTS as readonly unknown[]).includes(v) ? (v as Variant) : DEFAULT_VARIANT
}

export const sortOrder = (): SortOrder => {
  const v = setting("sort")
  return v === "created" || v === "title" ? v : "updated"
}

export const bodyLines = (): number => {
  const v = Number(setting("bodyLines"))
  return Number.isInteger(v) && v >= 1 && v <= MAX_RENDERED_LINES ? v : DEFAULT_BODY_LINES
}

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!

/** Moves to the next variant; the config layer owns the setting (`app.settings.set`). */
export async function cycleVariant(): Promise<{ variant: Variant }> {
  const next = nextVariant(variant())
  await cmux.app.settings.set({ variant: next })
  return { variant: next }
}
