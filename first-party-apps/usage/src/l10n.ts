// Localized strings. The platform has no app i18n API yet (README, gap 6), so the
// app carries its own English and Japanese tables and picks the language from
// the JS engine's Intl locale. `{name}` placeholders are filled from `vars`.

type Vars = Record<string, string | number>

const ja: Record<string, string> = {
  "window.session.hours": "{hours}時間",
  "window.session": "セッション",
  "window.weekly": "週間",
  "window.weekly.scoped": "{scope} 週間",
  "window.monthly": "月間",
  "window.daily": "日次",
  "window.budget": "予算",
  "window.credits": "クレジット",
  "duration.lessThanMinute": "1分未満",
  "duration.minutes": "{m}分",
  "duration.hoursMinutes": "{h}時間{m}分",
  "duration.daysHours": "{d}日{h}時間",
  "reset.in": "{duration}後にリセット",
  "reset.now": "まもなくリセット",
  "pace.runsOut": "{duration}後に上限に達する見込み",
  "pace.over": "想定より{delta}%多い",
  "stale.ago": "古いデータ · {duration}前に更新",
  "stale": "古いデータ",
  "spend.ofLimit": "{used} / {limit}",
  "unavailable.title": "使用量サービスがありません",
  "unavailable.message": "このビルドには使用量サービス ({op}) がまだありません。",
  "scope.title": "使用量を読む権限がありません",
  "scope.message": "設定 > アプリ > 使用量 で {scope} を許可してください。",
  "error.title": "使用量を読み込めません",
  "empty.title": "プランが見つかりません",
  "empty.message": "ターミナルで Claude Code か Codex にサインインすると、cmux がその使用量を表示します。",
  "loading": "読み込み中…",
  "menu.refresh": "今すぐ更新",
  "menu.show": "使用量を表示",
  "menu.noData": "使用量データがありません",
  "status.help": "{provider} · {window} · {percent}",
  "alert.title": "{provider} の{window}上限が {percent} に達しました",
  "alert.body": "{reset}。{pace}",
  "alert.bodyNoPace": "{reset}。",
  "pool": "プール"
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
