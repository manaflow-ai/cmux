// App settings (config layer, `cmux.json` apps."cmux/diffs".settings) with the
// manifest defaults, plus session overrides while apps cannot write their own
// settings (README, gaps).

export const VARIANTS = ["split", "stream", "review"] as const
export type Variant = (typeof VARIANTS)[number]
export const DEFAULT_VARIANT: Variant = "split"
export type Layout = "sideBySide" | "inline"

const [variantOverride, setVariantOverride] = signal<Variant | null>(null)
const [layoutOverride, setLayoutOverride] = signal<Layout | null>(null)

const setting = (key: string): unknown => cmux.app.settings()[key]

export const variant = (): Variant => {
  const v = variantOverride() ?? setting("variant")
  return (VARIANTS as readonly unknown[]).includes(v) ? (v as Variant) : DEFAULT_VARIANT
}

export const layout = (): Layout => {
  const v = layoutOverride() ?? setting("layout")
  return v === "sideBySide" ? "sideBySide" : "inline"
}

/** Preferred `cmux.editor/1` implementation for embeds; the user's open-with default wins. */
export const editorApp = (): string => {
  const v = setting("editorApp")
  return typeof v === "string" && /^[a-z0-9-]+\/[a-z0-9-]+$/.test(v) ? v : "cmux/codemirror"
}

/** Lines the built-in (scene) diff renders per file before "Show more" (the scene allows 4096 nodes per mount). */
export const fallbackLines = (): number => {
  const v = Number(setting("fallbackLines"))
  return Number.isInteger(v) && v >= 20 && v <= 600 ? v : 160
}

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!

async function persist(key: string, value: string): Promise<boolean> {
  try {
    await cmux.call("app.settings.set", { key, value })
    return true
  } catch {
    return false
  }
}

/** Next variant. Persists through the proposed `app.settings.set` (owner: config layer) when it exists. */
export async function cycleVariant(): Promise<{ variant: Variant; persisted: boolean }> {
  const next = nextVariant(variant())
  setVariantOverride(next)
  const persisted = await persist("variant", next)
  if (persisted && setting("variant") === next) setVariantOverride(null)
  return { variant: next, persisted }
}

export async function toggleLayout(): Promise<{ layout: Layout; persisted: boolean }> {
  const next: Layout = layout() === "inline" ? "sideBySide" : "inline"
  setLayoutOverride(next)
  const persisted = await persist("layout", next)
  if (persisted && setting("layout") === next) setLayoutOverride(null)
  return { layout: next, persisted }
}

export function setVariantForSession(v: Variant) {
  setVariantOverride(v)
}
