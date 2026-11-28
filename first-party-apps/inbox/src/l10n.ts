// App strings live in strings/<lang>.json (the platform's app l10n tables).
// t(key, params) has the shape of the runtime's cmux.t(key): the host's
// strings for the user's locale win; the bundled table is the fallback for
// hosts that do not pass strings yet, and English is the last resort.

import en from "../strings/en.json"
import ja from "../strings/ja.json"

type Params = Record<string, string | number>

const TABLES: Record<string, Record<string, string>> = { en, ja }
const EN: Record<string, string> = en

let forced: string | null = null

const hostLocale = (): string => {
  try {
    return typeof cmux !== "undefined" && cmux.app.locale ? cmux.app.locale : "en"
  } catch {
    return "en"
  }
}

/** The language of the bundled fallback table ("ja" for "ja-JP"). */
export const language = () => (forced ?? hostLocale()).toLowerCase().split("-")[0] ?? "en"

/** Tests and previews force a language; null returns to the host's locale. */
export function setLanguage(lang: string | null): void {
  forced = lang
}

const fill = (s: string, params: Params) => s.replace(/\{(\w+)\}/g, (whole, name: string) => (name in params ? String(params[name]) : whole))

export function t(key: string, params: Params = {}): string {
  const fallback = TABLES[language()]?.[key] ?? EN[key] ?? key
  if (forced === null && typeof cmux !== "undefined" && typeof cmux.t === "function") return cmux.t(key, fallback, params)
  return fill(fallback, params)
}
