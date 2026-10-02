// App settings (config layer, `cmux.json` apps."cmux/notes".settings) with the
// defaults from the manifest schema, plus a session override for variant
// cycling while apps cannot write their own settings (README, gaps).

import type { SortOrder } from "./model.ts"

export const VARIANTS = ["scratchpad", "list", "split"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "scratchpad"
export const DEFAULT_BODY_LINES = 12
/** Lines one note may render even when expanded (the scene allows 4096 nodes per mount). */
export const MAX_RENDERED_LINES = 400

const [variantOverride, setVariantOverride] = signal<Variant | null>(null)

const setting = (key: string): unknown => cmux.app.settings()[key]

export const variant = (): Variant => {
  const v = variantOverride() ?? setting("variant")
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

/**
 * Moves to the next variant. Tries the proposed `app.settings.set` (owner: the
 * config layer) so the choice persists; without it the choice lasts until the
 * app restarts.
 */
export async function cycleVariant(): Promise<{ variant: Variant; persisted: boolean }> {
  const next = nextVariant(variant())
  setVariantOverride(next)
  try {
    await cmux.call("app.settings.set", { key: "variant", value: next })
    // The config layer now owns the value; a later edit in Settings must win.
    if (setting("variant") === next) setVariantOverride(null)
    return { variant: next, persisted: true }
  } catch {
    return { variant: next, persisted: false }
  }
}
