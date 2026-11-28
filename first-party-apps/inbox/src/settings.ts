/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// App settings (`contributes.settings`, owned by the config layer).

import type { GroupBy } from "./feed.ts"

export type Variant = "grouped" | "focus" | "card"
export const VARIANTS: readonly Variant[] = ["grouped", "focus", "card"]
export const DEFAULT_VARIANT: Variant = "grouped"

export interface Settings {
  variant: Variant
  groupBy: GroupBy
}

export const asVariant = (v: unknown): Variant => (VARIANTS.includes(v as Variant) ? (v as Variant) : DEFAULT_VARIANT)
export const asGroupBy = (v: unknown): GroupBy => (v === "workspace" || v === "thread" ? v : "poster")

/** Normalizes raw settings (missing or malformed keys get their documented defaults). */
export const readSettings = (raw: Record<string, unknown>): Settings => ({ variant: asVariant(raw.variant), groupBy: asGroupBy(raw.groupBy) })

export const settings = (): Settings => readSettings(cmux.app.settings())
