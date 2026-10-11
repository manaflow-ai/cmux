// Design variants (DEV/NIGHTLY switch; picked after dogfood).
//
// The `variant` app setting selects one. `cycleVariant` writes the setting
// with `cmux.app.settings.set`; a host without it keeps an override in
// cmux.storage that applies only while the setting still has the value it
// overrode, so a later change in Settings wins.

export const VARIANTS = ["menu", "pane"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "menu"

const OVERRIDE_KEY = "variantOverride"
type Override = { value: Variant; base: string | null }

const [override, setOverride] = signal<Override | null>(null)
let loaded = false

export const isVariant = (v: unknown): v is Variant => typeof v === "string" && (VARIANTS as readonly string[]).includes(v)

const settingValue = (): string | null => {
  const v = cmux.app.settings().variant
  return typeof v === "string" ? v : null
}

export const variant = computed<Variant>(() => {
  const setting = settingValue()
  const o = override()
  if (o && o.base === setting) return o.value
  return isVariant(setting) ? setting : DEFAULT_VARIANT
})

export function loadVariantOverride(): void {
  if (loaded) return
  loaded = true
  cmux.storage
    .get<Override>(OVERRIDE_KEY)
    .then((o) => {
      if (o && isVariant(o.value)) setOverride(o)
    })
    .catch(() => {})
}

export const nextVariant = (current: Variant): Variant => VARIANTS[(VARIANTS.indexOf(current) + 1) % VARIANTS.length]!

export async function cycleVariant(): Promise<{ variant: Variant; persisted: "setting" | "storage" }> {
  const next = nextVariant(variant())
  try {
    await cmux.app.settings.set({ variant: next })
    setOverride(null)
    await cmux.storage.delete(OVERRIDE_KEY).catch(() => null)
    return { variant: next, persisted: "setting" }
  } catch {
    const o: Override = { value: next, base: settingValue() }
    setOverride(o)
    await cmux.storage.set(OVERRIDE_KEY, o).catch(() => null)
    return { variant: next, persisted: "storage" }
  }
}
