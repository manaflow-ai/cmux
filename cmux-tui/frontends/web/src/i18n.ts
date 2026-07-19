const messages = {
  en: {
    appName: "cmux-tui web",
    appTagline: "A reference frontend for the cmux WebSocket API",
    wsUrl: "WebSocket URL",
    token: "Token (optional)",
    connect: "Connect",
    connecting: "Connecting…",
    reconnecting: "Connection lost. Reconnecting in {seconds}s (attempt {attempt})…",
    workspaces: "Workspaces",
    noSessions: "No workspaces are available.",
    noSurface: "The active pane has no live terminal surface.",
    browserSurface: "Browser surfaces are not rendered by this reference frontend yet.",
    terminal: "Terminal",
    session: "Session",
    connection: "Connection",
    protocol: "Protocol",
    connected: "Connected",
    disconnected: "Disconnected",
    closeNotification: "Dismiss notification",
    unread: "Unread notification",
    screen: "Screen {number}",
    tab: "Tab {number}",
    unknownError: "Unable to connect.",
    wrongApp: "Expected a cmux-tui server, but received {app}.",
    wrongProtocol: "Protocol 6 is required; the server reported protocol {protocol}.",
    openWorkspaces: "Open workspaces",
    closeWorkspaces: "Close workspaces",
    extraKeys: "Terminal extra keys",
    keyEscape: "Esc",
    keyTab: "Tab",
    keyControl: "Ctrl",
    keyLeft: "Left arrow",
    keyDown: "Down arrow",
    keyUp: "Up arrow",
    keyRight: "Right arrow",
    keyPrefix: "C-b",
  },
  ja: {
    appName: "cmux-tui ウェブ",
    appTagline: "cmux WebSocket API のリファレンスフロントエンド",
    wsUrl: "WebSocket URL",
    token: "トークン（任意）",
    connect: "接続",
    connecting: "接続中…",
    reconnecting: "接続が切れました。{seconds}秒後に再接続します（{attempt}回目）…",
    workspaces: "ワークスペース",
    noSessions: "利用できるワークスペースがありません。",
    noSurface: "アクティブなペインに有効なターミナルサーフェスがありません。",
    browserSurface: "このリファレンスフロントエンドでは、ブラウザサーフェスはまだ表示できません。",
    terminal: "ターミナル",
    session: "セッション",
    connection: "接続",
    protocol: "プロトコル",
    connected: "接続済み",
    disconnected: "未接続",
    closeNotification: "通知を閉じる",
    unread: "未読の通知",
    screen: "スクリーン {number}",
    tab: "タブ {number}",
    unknownError: "接続できませんでした。",
    wrongApp: "cmux-tui サーバーが必要ですが、{app} を受信しました。",
    wrongProtocol: "プロトコル6が必要ですが、サーバーはプロトコル{protocol}を返しました。",
    openWorkspaces: "ワークスペースを開く",
    closeWorkspaces: "ワークスペースを閉じる",
    extraKeys: "ターミナル追加キー",
    keyEscape: "Esc",
    keyTab: "Tab",
    keyControl: "Ctrl",
    keyLeft: "左矢印",
    keyDown: "下矢印",
    keyUp: "上矢印",
    keyRight: "右矢印",
    keyPrefix: "C-b",
  },
} as const;

type Locale = keyof typeof messages;
type MessageKey = keyof typeof messages.en;
type Params = Record<string, string | number>;

export function locale(): Locale {
  return typeof navigator !== "undefined" && navigator.language.toLowerCase().startsWith("ja") ? "ja" : "en";
}

export function t(key: MessageKey, params: Params = {}): string {
  let value: string = messages[locale()][key];
  for (const [name, replacement] of Object.entries(params)) {
    value = value.replaceAll(`{${name}}`, String(replacement));
  }
  return value;
}

export { messages };
