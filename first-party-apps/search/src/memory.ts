/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// What the app remembers per machine (cmux.storage): recent searches, which
// results the user opened (a ranking signal), and the dev-only variant
// override. Storage failures never break search: values stay in memory.

import { markOpened, pushRecent } from "./recents.ts"
import { isVariant, settings, type Variant } from "./settings.ts"

const [recentSig, setRecent] = signal<string[]>([])
const [openedSig, setOpened] = signal<Record<string, number>>({})
const [variantSig, setVariant] = signal<string | null>(null)
let loaded: Promise<void> | null = null

export const recent = recentSig
export const opened = openedSig
export const variantOverride = variantSig

async function read<T>(key: string, fallback: T): Promise<T> {
  try {
    return ((await cmux.storage.get<T>(key)) ?? fallback) as T
  } catch {
    return fallback
  }
}

const write = (key: string, value: unknown) => cmux.storage.set(key, value).catch(() => undefined)

/** Loads stored values once per app VM. */
export function loadMemory(): Promise<void> {
  loaded ??= (async () => {
    const [r, o, v] = await Promise.all([read<string[]>("recent", []), read<Record<string, number>>("opened", {}), read<string | null>("variant", null)])
    setRecent(Array.isArray(r) ? r.filter((x) => typeof x === "string") : [])
    setOpened(o && typeof o === "object" && !Array.isArray(o) ? Object.fromEntries(Object.entries(o).filter(([, v]) => typeof v === "number")) : {})
    setVariant(typeof v === "string" ? v : null)
  })()
  return loaded
}

export function rememberSearch(query: string, enabled: boolean) {
  if (!enabled) return
  const next = pushRecent(recentSig(), query)
  setRecent(next)
  void write("recent", next)
}

export function rememberOpened(id: string, nowMs: number) {
  const next = markOpened(openedSig(), id, nowMs)
  setOpened(next)
  void write("opened", next)
}

export function clearMemory() {
  setRecent([])
  setOpened({})
  return Promise.all([cmux.storage.delete("recent"), cmux.storage.delete("opened")]).catch(() => undefined)
}

export function storeVariant(variant: string) {
  setVariant(variant)
  void write("variant", variant)
}

/** The variant shown: the dev-only override from "Next Search Variant" wins over the setting. */
export const currentVariant = (): Variant => {
  const o = variantSig()
  return isVariant(o) ? o : settings().variant
}
