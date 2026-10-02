// Tiny string table until the platform has an app i18n API (README, gaps).
// `t(key, english, vars)` returns the string for the current language with
// `{name}` placeholders filled in. English is the fallback for every key.

const ja: Record<string, string> = {
  "section.title": "メモ",
  "search.placeholder": "メモを検索",
  "append.placeholder": "行を追加",
  "scratchpad.placeholder": "このワークスペースにメモ",
  "title.placeholder": "タイトル",
  "line.placeholder": "行を編集",
  "note.untitled": "無題",
  "note.empty": "空のメモ",
  "list.pinned": "ピン留め",
  "list.workspace": "このワークスペース",
  "list.recent": "最近",
  "list.other": "ほかのメモ",
  "empty.title": "メモはありません",
  "empty.message": "「新規メモ」で作成するか、エージェントにメモを頼んでください。",
  "empty.search": "一致するメモはありません",
  "empty.select": "メモを選択してください",
  "scratchpad.title": "スクラッチパッド",
  "scratchpad.none": "ワークスペースを選んでいません",
  "scratchpad.closed": "{name}(閉じています)",
  "error.load": "メモを読み込めません",
  "error.save": "メモを保存できません",
  "error.storage": "ストレージを使えません",
  "action.new": "新規メモ",
  "action.pin": "ピン留め",
  "action.unpin": "ピン留めを外す",
  "action.delete": "削除",
  "action.back": "戻る",
  "action.showMore": "あと{n}行を表示",
  "action.showLess": "折りたたむ",
  "action.editLine": "行を編集",
  "action.deleteLine": "行を削除",
  "action.attach": "このワークスペースに付ける",
  "action.detach": "ワークスペースから外す",
  "action.copyId": "IDをコピー",
  "edited.agent": "エージェントが編集",
  "time.now": "今",
  "time.minutes": "{n}分",
  "time.hours": "{n}時間",
  "time.days": "{n}日",
  "backend.local": "このMacのみ",
  "error.tooLarge": "メモが大きすぎます",
  "error.notFound": "メモが見つかりません",
  "error.invalid": "引数が正しくありません",
  "limit.lines": "長いメモです。表示は先頭の{n}行までです。"
}

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

/** Keys of the Japanese table (tests check every t() key used in src has a translation). */
export const translatedKeys = (lang: string) => Object.keys(tables[lang] ?? {})
