// Localized strings in the platform v2 shape (`strings/<lang>.json`,
// `cmux.t(key)`). Today's hosts do not load an app's string tables, so the
// tables are bundled into dist/main.js and the language comes from the host
// locale or the JS engine's Intl. When a host does pass the app's strings,
// `cmux.t` answers first. `{name}` placeholders are filled from `vars`.
// test/l10n.test.ts checks that both tables cover every t() key in src/.

import en from "../strings/en.json"
import ja from "../strings/ja.json"

type Vars = Record<string, string | number>

const tables: Record<string, Record<string, string>> = { en, ja }
const MISSING = "\u0000"

let language: string | null = null

function detect(): string {
  try {
    const host = cmux.app.locale
    if (typeof host === "string" && host && host !== "en") return host
  } catch {
    // no host (tests that load modules directly)
  }
  try {
    return new Intl.DateTimeFormat().resolvedOptions().locale || "en"
  } catch {
    return "en"
  }
}

/** Sets the language from a BCP 47 tag ("ja-JP" -> "ja"); unknown languages fall back to English. */
export function setLanguage(tag: string | null | undefined): void {
  const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en"
  language = tables[base] ? base : "en"
}

export function currentLanguage(): string {
  if (language === null) setLanguage(detect())
  return language!
}

const fill = (template: string, vars: Vars) => template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole))

/** The string for `key` in the current language, else `english`. */
export function t(key: string, english: string, vars: Vars = {}): string {
  let hosted: string | null = null
  try {
    const v = cmux.t(key, MISSING)
    if (v !== MISSING) hosted = v
  } catch {
    // no host
  }
  return fill(hosted ?? tables[currentLanguage()]?.[key] ?? english, vars)
}

/** Keys of a bundled table (tests). */
export const translatedKeys = (lang: string) => Object.keys(tables[lang] ?? {})
