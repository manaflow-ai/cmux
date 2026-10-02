// Every user-visible string goes through t(key, english). The platform has no
// app i18n API yet (no locale in init or mount context), so the locale comes
// from the engine's Intl when it has one, else English.

type Vars = Record<string, string | number>

const ja: Record<string, string> = {
  "app.title": "受信トレイ",
  "action.done": "完了にする",
  "action.doneShort": "完了",
  "action.markAllDone": "すべて完了にする",
  "action.markAllSeen": "すべて既読にする",
  "action.markSeen": "既読にする",
  "action.more": "その他",
  "action.open": "開く",
  "action.respond": "回答",
  "action.skip": "スキップ",
  "action.snooze": "スヌーズ",
  "action.unsnooze": "スヌーズを解除",
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
  "snooze.30m": "30分後 ({time})",
  "snooze.2h": "2時間後 ({time})",
  "snooze.tomorrow": "明日 ({time})",
  "snooze.nextWeek": "来週 ({time})",
  "snooze.until": "{time} までスヌーズ",
  "snoozed.count": "スヌーズ中 {n} 件",
  "snoozed.hide": "スヌーズ中を隠す",
  "snoozed.show": "スヌーズ中を表示",
  "snoozed.title": "スヌーズ中",
  "card.position": "{index} / {total}",
  "detail.none": "項目を選んでください",
  "empty.filtered": "このフィルターに一致する項目はありません",
  "empty.message": "エージェント、アプリ、連携はすべて片付いています。",
  "empty.title": "対応が必要なものはありません",
  "feed.error": "フィードを読み込めません",
  "feed.notGranted": "フィードへのアクセスが許可されていません",
  "feed.notGrantedHelp": "設定 > アプリ > 受信トレイ で許可してください。",
  "feed.unavailable": "フィードはまだ利用できません",
  "feed.unavailableHelp": "このバージョンの cmux にはフィードの管理元がありません。",
  "error.feed": "フィードが受け付けませんでした: {reason}",
  "error.open": "開けませんでした: {reason}",
  "filter.all": "すべて",
  "filter.everything": "すべて表示",
  "filter.needsResponse": "回答が必要なものだけ表示",
  "filter.needsResponseShort": "要対応",
  "filter.other": "アプリと実行",
  "filter.showSeen": "既読も表示",
  "filter.unseenOnly": "未読のみ表示",
  "filter.unseenShort": "未読",
  "group.source": "ソース別にまとめる",
  "group.thread": "スレッド別にまとめる",
  "group.workspace": "ワークスペース別にまとめる",
  "item.noneSelected": "受信トレイの項目が選択されていません",
  "item.notFound": "受信トレイに {id} はありません",
  "kind.watch": "進行中",
  "loading": "読み込み中…",
  "pane.unsupported": "このバージョンの cmux はアプリのペインをまだ開けません。サイドバーのセクションを使ってください。",
  "reason.scope": "許可されていません",
  "reason.unsupported": "このバージョンの cmux では使えません",
  "request.approve": "承認",
  "request.choice": "選択",
  "request.confirm": "確認",
  "request.file": "ファイル",
  "request.handoff": "引き継ぎ",
  "request.input": "入力",
  "request.passkey": "パスキー",
  "request.question": "質問",
  "request.review": "レビュー",
  "request.sign-in": "サインイン",
  "respond.approve": "承認",
  "respond.cancel": "キャンセル",
  "respond.confirm": "確認",
  "respond.continueInBrowser": "ブラウザで続ける",
  "respond.deny": "拒否",
  "respond.externalHelp": "隣に開くブラウザタブで完了してください。エージェントはその後に再開し、認証情報を見ることはありません。",
  "respond.placeholder": "回答…",
  "source.agent": "エージェント",
  "source.app": "アプリ",
  "source.integration": "連携",
  "source.run": "実行",
  "source.user": "ユーザー",
  "status.none": "対応が必要なものはありません",
  "status.summary": "未読 {unseen} 件、回答が必要 {needs} 件"
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
