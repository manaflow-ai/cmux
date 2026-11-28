// App settings with manifest defaults, plus a session override for the
// variant until every host honors app.settings.set.

export const VARIANTS = ["unified", "byAgent", "byScope"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "unified"

const [override, setOverride] = signal<Variant | null>(null)

const setting = (key: string): unknown => cmux.app.settings()[key]

export const variant = (): Variant => {
  const v = override() ?? setting("variant")
  return (VARIANTS as readonly unknown[]).includes(v) ? (v as Variant) : DEFAULT_VARIANT
}

/** Where a planned change's diff shows first: inline in this app, or the Diffs app. */
export const reviewIn = (): "inline" | "diffs" => (setting("reviewIn") === "diffs" ? "diffs" : "inline")

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!

export async function cycleVariant(): Promise<{ variant: Variant; persisted: boolean }> {
  const next = nextVariant(variant())
  setOverride(next)
  try {
    await cmux.app.settings.set({ variant: next })
    return { variant: next, persisted: true }
  } catch {
    return { variant: next, persisted: false }
  }
}
