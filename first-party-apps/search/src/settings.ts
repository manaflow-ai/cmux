/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// App settings (cmux.json `apps."cmux/search".settings`) with their defaults.
// The defaults here must match cmux-app.json; test/settings.test.ts checks it.

import { SOURCES, isSourceId, type Scope, type SourceId } from "./query.ts"

export const VARIANTS = ["grouped", "preview", "palette"] as const
export type Variant = (typeof VARIANTS)[number]

export interface Settings {
  variant: Variant
  defaultScope: Scope
  rememberRecent: boolean
  sources: SourceId[]
}

export const DEFAULTS: Settings = { variant: "grouped", defaultScope: "all", rememberRecent: true, sources: [...SOURCES] }

export const isVariant = (v: unknown): v is Variant => typeof v === "string" && (VARIANTS as readonly string[]).includes(v)

/** Normalizes raw settings: unknown or invalid values fall back to the defaults. Pure. */
export function readSettings(raw: Record<string, unknown>): Settings {
  const sources = Array.isArray(raw.sources) ? SOURCES.filter((s) => (raw.sources as unknown[]).includes(s)) : DEFAULTS.sources
  return {
    variant: isVariant(raw.variant) ? raw.variant : DEFAULTS.variant,
    defaultScope: raw.defaultScope === "workspace" ? "workspace" : "all",
    rememberRecent: raw.rememberRecent !== false,
    sources: sources.filter(isSourceId)
  }
}

export const settings = (): Settings => readSettings(cmux.app.settings())

export const nextVariant = (v: Variant): Variant => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length]!
