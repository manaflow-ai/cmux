// Localized strings (`strings/<lang>.json`, `cmux.t(key)`). Hosts do not load an app's string
// tables yet, so both tables are bundled and the language comes from the host locale. When a host
// does pass the app's strings, `cmux.t` answers first. test/l10n.test.ts checks the tables cover
// every t() key in src/.

import { cmux } from "cmux-extension-sdk"
import en from "../strings/en.json"
import ja from "../strings/ja.json"

type Vars = Record<string, string | number>

const tables: Record<string, Record<string, string>> = { en, ja }
const MISSING = "\u0000"

function language(): string {
  let tag = "en"
  try {
    tag = String(cmux.app.locale || "en")
  } catch {
    // no host
  }
  const base = tag.toLowerCase().split(/[-_]/)[0] ?? "en"
  return tables[base] ? base : "en"
}

const fill = (template: string, vars: Vars) => template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole))

/** The string for `key` in the person's language, else `english`. */
export function t(key: string, english: string, vars: Vars = {}): string {
  let hosted: string | null = null
  try {
    const v = cmux.t(key, MISSING)
    if (v !== MISSING) hosted = v
  } catch {
    // no host
  }
  return fill(hosted ?? tables[language()]?.[key] ?? english, vars)
}
