// Localized strings. The platform has no app i18n API yet, so the app carries
// its own tables: English is the default argument, Japanese is below. `{name}`
// placeholders are filled by `t(key, english, {name: value})`.

const ja: Record<string, string> = {
  "field.placeholder": "検索",
  "field.placeholder.long": "ワークスペース、ターミナル、ページ、ファイルを検索",
  "source.workspaces": "ワークスペース",
  "source.terminals": "ターミナル",
  "source.browser": "ブラウザ",
  "source.apps": "アプリ",
  "source.files": "ファイル",
  "filter.all": "すべて",
  "scope.workspace": "このワークスペース",
  "scope.all": "すべての場所",
  "regex.toggle": ".*",
  "regex.help": "正規表現",
  "recent.title": "最近の検索",
  "recent.clear": "最近の検索を消去",
  "more": "さらに {count} 件",
  "more.unknown": "さらに結果があります",
  "empty.title": "すべてを検索",
  "empty.message": "t: ターミナル、f: ファイル、b: ブラウザ、w: ワークスペース、a: アプリ。/正規表現/ も使えます。",
  "none.title": "一致なし",
  "none.message": "「{query}」に一致する項目はありません",
  "none.here": "ここには一致なし。in:all を試してください。",
  "invalid.title": "正規表現が無効です",
  "searching": "検索中…",
  "open": "開く",
  "location.closed": "終了済み",
  "screenOnly": "表示中の画面のみ",
  "missing.terminals": "ターミナルの履歴検索には terminal.search が必要です（表示中の画面のみ検索しました）",
  "missing.browser": "閲覧履歴の検索には browser.history.search が必要です",
  "missing.files": "ファイル検索には fs.search が必要です",
  "missing.files.noRoots": "検索するフォルダがありません（ターミナルの作業ディレクトリから決まります）",
  "missing.apps": "他のアプリの検索には search.providers.query が必要です",
  "missing.workspaces": "名前の検索には session.snapshot が必要です",
  "missing.scope": "{source}: アクセスが許可されていません",
  "missing.generic": "{source}: 検索できません（{code}）",
  "hint.palette": "↩ 開く  ⎋ 消去",
  "preview.none": "結果を選ぶとここに表示されます"
}

const tables: Record<string, Record<string, string>> = { ja }
let locale = "en"

/** Sets the language from the host locale (BCP 47); unknown languages use English. */
export function setLocale(tag: string | null | undefined) {
  const lang = (tag ?? "en").toLowerCase().split(/[-_]/)[0]!
  locale = tables[lang] ? lang : "en"
}

export const currentLocale = () => locale

export function t(key: string, english: string, vars: Record<string, string | number> = {}): string {
  const template = tables[locale]?.[key] ?? english
  return template.replace(/\{(\w+)\}/g, (m, name: string) => (name in vars ? String(vars[name]) : m))
}

/** Every key with a Japanese entry (tests check English callers use only these). */
export const jaKeys = () => Object.keys(ja)
