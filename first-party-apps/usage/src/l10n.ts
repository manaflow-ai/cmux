// Localized strings. The platform has no app i18n API yet (README, gap 6), so the
// app carries its own English and Japanese tables and picks the language from
// the JS engine's Intl locale. `{name}` placeholders are filled from `vars`.

type Vars = Record<string, string | number>

const ja: Record<string, string> = {
  "advice.over": "負荷を下げる",
  "advice.under": "負荷を上げる",
  "alert.body": "{total} 個のアカウントがすべて使い切り、冷却中、またはエラーです。",
  "alert.title": "使える {provider} アカウントがありません",
  "column.account": "アカウント",
  "column.pace": "ペース",
  "column.session": "5時間",
  "column.state": "状態",
  "column.weekly": "週",
  "duration.daysHours": "{d}日{h}時間",
  "duration.hoursMinutes": "{h}時間{m}分",
  "duration.lessThanMinute": "1分未満",
  "duration.minutes": "{m}分",
  "empty.message": "ルーターにアカウントを追加すると (sr add)、cmux がここに使用量を表示します。",
  "empty.title": "アカウントが見つかりません",
  "error.title": "使用量を読み込めません",
  "extra": "追加 ${usd}",
  "loading": "読み込み中…",
  "menu.noData": "使用量データがありません",
  "menu.refresh": "今すぐ更新",
  "menu.show": "使用量を表示",
  "pace.account": "ペース {ratio}",
  "scope.message": "設定 > アプリ > 使用量 で {scope} を許可してください。",
  "scope.title": "使用量を読む権限がありません",
  "stale.ago": "古いデータ · {duration}前に更新",
  "stale": "古いデータ",
  "state.active": "使用中",
  "state.cooked": "使い切り",
  "state.error": "エラー",
  "state.protected": "保留",
  "state.ready": "待機",
  "state.rec": "次候補",
  "state.temp": "冷却中",
  "state.unknown": "不明",
  "summary.burn": "{actual}%/時 (理想 {ideal}%/時)",
  "summary.ideal": "理想 {ideal}%/時",
  "summary.left": "残り {left}",
  "summary.usable": "{total} 中 {usable} 個が使用可能",
  "unavailable.message": "このビルドには使用量サーバー ({op}) がまだありません。",
  "unavailable.title": "使用量サーバーがありません",
  "usableBadge": "{usable}/{total}",
  "verdict.none": "残りなし",
  "verdict.onPace": "ペース通り",
  "verdict.over": "ペース超過",
  "verdict.pending": "30分後にペース",
  "verdict.under": "ペース不足",
  "verdict.unmetered": "週間上限なし",
  "window.leftReset": "{left} · {reset}",
  "window.session": "5時間 {text}",
  "window.weekly": "週 {text}"
}

const tables: Record<string, Record<string, string>> = { ja }

let locale = detectLocale()

function detectLocale(): string {
  try {
    return new Intl.DateTimeFormat().resolvedOptions().locale || "en"
  } catch {
    return "en"
  }
}

/** For tests and hosts that know the user's language better than Intl. */
export function setLocale(next: string): void {
  locale = next
}

export function currentLanguage(): string {
  return locale.split(/[-_]/)[0]!.toLowerCase()
}

/** Looks up `key` in the current language, falling back to `english`. */
export function t(key: string, english: string, vars: Vars = {}): string {
  const template = tables[currentLanguage()]?.[key] ?? english
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole))
}
