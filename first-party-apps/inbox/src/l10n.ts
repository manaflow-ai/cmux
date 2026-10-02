// Every user-visible string goes through t(key, english). The platform has no
// app i18n API yet (no locale in init or mount context), so the locale comes
// from the engine's Intl when it has one, else English.

type Vars = Record<string, string | number>

const ja: Record<string, string> = {
  "app.title": "受信トレイ",
  "kind.agentBlocked": "入力待ち",
  "kind.agentDone": "完了",
  "kind.agentIdle": "待機中",
  "kind.notification": "通知",
  "kind.reviewRequested": "レビュー依頼",
  "kind.checksFailing": "チェック失敗",
  "kind.mention": "メンション",
  "source.all": "すべて",
  "source.agent": "エージェント",
  "source.notification": "通知",
  "source.github": "GitHub",
  "group.other": "その他",
  "agent.fallback": "エージェント",
  "filter.unreadOnly": "未読のみ表示",
  "filter.showAll": "既読も表示",
  "filter.mineOnly": "自分の作業のみ",
  "filter.includeRequests": "依頼も表示",
  "filter.groupBySource": "ソース別にまとめる",
  "filter.groupByWorkspace": "ワークスペース別にまとめる",
  "filter.unreadSuffix": "{label}・未読",
  "action.open": "開く",
  "action.done": "完了にする",
  "action.doneShort": "完了",
  "action.snooze": "スヌーズ",
  "action.skip": "スキップ",
  "action.markRead": "既読にする",
  "action.markAllRead": "すべて既読にする",
  "action.markAllDone": "すべて完了にする",
  "action.unsnooze": "スヌーズを解除",
  "action.refresh": "更新",
  "action.reply": "返信…",
  "snooze.30m": "30分後 ({time})",
  "snooze.2h": "2時間後 ({time})",
  "snooze.tomorrow": "明日 ({time})",
  "snooze.nextWeek": "来週 ({time})",
  "snooze.until": "{time} までスヌーズ",
  "snoozed.count": "スヌーズ中 {n} 件",
  "snoozed.hide": "スヌーズ中を隠す",
  "ago.now": "今",
  "ago.m": "{n}分",
  "ago.h": "{n}時間",
  "ago.d": "{n}日",
  "ago.w": "{n}週",
  "day.0": "日",
  "day.1": "月",
  "day.2": "火",
  "day.3": "水",
  "day.4": "木",
  "day.5": "金",
  "day.6": "土",
  "time.tomorrow": "明日 {time}",
  "time.weekday": "{day} {time}",
  "card.position": "{index} / {total}",
  "badge.unread": "未読 {n} 件",
  "empty.title": "対応が必要なものはありません",
  "empty.message": "エージェント、通知、GitHub はすべて片付いています。",
  "empty.filtered": "このフィルターに一致する項目はありません",
  "loading": "読み込み中…",
  "error.notification": "通知を読み込めません: {reason}",
  "error.agent": "エージェントを読み込めません: {reason}",
  "error.open": "開けませんでした: {reason}",
  "error.reply": "送信できませんでした: {reason}",
  "reason.scope": "許可されていません",
  "reason.unsupported": "このバージョンの cmux では使えません",
  "github.notGranted": "GitHub を接続",
  "github.notGrantedHelp": "設定 > アプリ > 受信トレイ で GitHub の読み取りを許可します",
  "github.unavailable": "GitHub 連携はまだ利用できません",
  "github.unavailableHelp": "cmux の連携ゲートウェイがこのホストにありません",
  "github.error": "GitHub を読み込めません",
  "github.checks.fail": "{n} 件失敗: {names}",
  "github.checks.pending": "チェック実行中",
  "github.checks.pass": "すべてのチェックに成功",
  "github.checks.neutral": "チェック結果なし",
  "github.by": "{author} が作成",
  "reply.needsScope": "クイック返信にはターミナルへの入力許可が必要です (設定 > アプリ > 受信トレイ)。",
  "reply.sent": "送信しました",
  "detail.none": "項目を選んでください",
  "status.none": "対応が必要なものはありません",
  "pane.unsupported": "このバージョンの cmux はアプリのペインをまだ開けません。サイドバーのセクションを使ってください。",
  "item.notFound": "受信トレイに {id} はありません",
  "variant.grouped": "グループ表示",
  "variant.focus": "リストと詳細",
  "variant.card": "1件ずつ"
}

const tables: Record<string, Record<string, string>> = { ja }

const detect = (): string => {
  try {
    const intl = (globalThis as { Intl?: typeof Intl }).Intl
    const locale = intl?.DateTimeFormat?.().resolvedOptions?.().locale
    if (typeof locale === "string" && locale) return locale.toLowerCase()
  } catch {
    // Engines without Intl (QuickJS builds without it) fall back to English.
  }
  return "en"
}

let language = detect().split("-")[0] ?? "en"

/** Overrides the detected language (tests, and hosts that pass a locale later). */
export function setLanguage(next: string): void {
  language = next.toLowerCase().split("-")[0] ?? "en"
}

export const currentLanguage = () => language

/** Looks up `key` in the current language, falls back to `english`, then fills `{name}` placeholders. */
export function t(key: string, english: string, vars: Vars = {}): string {
  const template = tables[language]?.[key] ?? english
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole))
}

/** Keys with a translation in each non-English table (tests check coverage). */
export const translationKeys = (lang: string): string[] => Object.keys(tables[lang] ?? {})
