// String tables in the platform v2 shape (`strings/<lang>.json`), bundled into
// dist/main.js so every host shows them even before it passes `strings` at init.
// `t(key, english, vars)`: English at the call site is the fallback; the test
// test/l10n.test.ts checks that both tables cover every key the source uses.

import en from "../strings/en.json"
import ja from "../strings/ja.json"

const tables: Record<string, Record<string, string>> = { en, ja }

let language = "en"

/** "ja-JP" -> "ja"; unknown languages fall back to English. */
export function setLanguage(tag: string | null | undefined): void {
  const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en"
  language = tables[base] ? base : "en"
}

export const currentLanguage = () => language

/** The host passes the locale at init (`cmux.app.locale`); a mount context may override it. */
export function detectLanguage(ctx?: { locale?: unknown } | null): string {
  if (ctx && typeof ctx.locale === "string") return ctx.locale
  try {
    return typeof cmux !== "undefined" && cmux.app?.locale ? cmux.app.locale : "en"
  } catch {
    return "en"
  }
}

export function t(key: string, english: string, vars: Record<string, string | number> = {}): string {
  const template = tables[language]?.[key] ?? english
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole))
}

export const translatedKeys = (lang: string) => Object.keys(tables[lang] ?? {})
