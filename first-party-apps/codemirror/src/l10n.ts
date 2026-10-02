// Shared by the editor apps (identical in first-party-apps/{monaco,codemirror}).
// String tables shaped like platform v2 app l10n (`strings/<lang>.json`,
// `cmux.t(key)`), bundled into the app scripts until the runtime loads them.
// `t(key, english, vars)` returns the string for the current language with
// `{name}` placeholders filled in. English at the call site is the fallback;
// test/l10n.test.ts checks that strings/en.json and strings/ja.json cover
// every key the source uses.

import ja from "../strings/ja.json"

const tables: Record<string, Record<string, string>> = { ja }

let language = "en"

/** Sets the language from a BCP 47 tag ("ja-JP" -> "ja"). Unknown languages fall back to English. */
export function setLanguage(tag: string | null | undefined): void {
  const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en"
  language = tables[base] ? base : "en"
}

export const currentLanguage = () => language

/** The host gives no locale yet; JavaScriptCore has Intl, QuickJS may not. */
export function detectLanguage(ctx?: { locale?: unknown } | null): string {
  if (ctx && typeof ctx.locale === "string") return ctx.locale
  try {
    const intl = (globalThis as { Intl?: typeof Intl }).Intl
    if (intl) return intl.DateTimeFormat().resolvedOptions().locale
  } catch {
    // fall through
  }
  return "en"
}

export function t(key: string, english: string, vars: Record<string, string | number> = {}): string {
  const template = tables[language]?.[key] ?? english
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole))
}

/** Keys of a language table (tests check every t() key used in src has a translation). */
export const translatedKeys = (lang: string) => Object.keys(tables[lang] ?? {})
