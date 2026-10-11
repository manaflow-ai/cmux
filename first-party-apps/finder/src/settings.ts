// App settings (cmux.json apps."cmux/finder".settings) with manifest defaults,
// plus a session override for the variant until the host honors app.settings.set.

export const VARIANTS = ["listPreview", "columns", "dualPane"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "listPreview"

const [variantOverride, setVariantOverride] = signal<Variant | null>(null)

const setting = (key: string): unknown => cmux.app.settings()[key]

export const variant = (): Variant => {
  const v = variantOverride() ?? setting("variant")
  return (VARIANTS as readonly unknown[]).includes(v) ? (v as Variant) : DEFAULT_VARIANT
}

export const showPreview = (): boolean => setting("showPreview") !== false

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!

export async function cycleVariant(): Promise<{ variant: Variant; persisted: boolean }> {
  const next = nextVariant(variant())
  setVariantOverride(next)
  let persisted = false
  try {
    await cmux.app.settings.set({ variant: next })
    persisted = true
  } catch {
    persisted = false
  }
  return { variant: next, persisted }
}
