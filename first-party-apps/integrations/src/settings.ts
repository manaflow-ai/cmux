// App settings (config layer, `cmux.json` apps."cmux/integrations".settings)
// with the manifest defaults, plus a session override while the runtime cannot
// persist (cmux.app.settings.set answers operation.unsupported on older hosts).

export const VARIANTS = ["connections", "gallery", "catalog"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "connections"

const [variantOverride, setVariantOverride] = signal<Variant | null>(null)

const setting = (key: string): unknown => cmux.app.settings()[key]

export const variant = (): Variant => {
  const v = variantOverride() ?? setting("variant")
  return (VARIANTS as readonly unknown[]).includes(v) ? (v as Variant) : DEFAULT_VARIANT
}

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!

/** Next variant; persists through `cmux.app.settings.set` when the host has it. */
export async function cycleVariant(): Promise<{ variant: Variant; persisted: boolean }> {
  const next = nextVariant(variant())
  setVariantOverride(next)
  try {
    await cmux.app.settings.set({ variant: next })
    if (setting("variant") === next) setVariantOverride(null)
    return { variant: next, persisted: true }
  } catch {
    return { variant: next, persisted: false }
  }
}
