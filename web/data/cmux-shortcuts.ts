export type LocalizedText = {
  en: string;
  ja: string;
};

export type Shortcut = {
  id: string;
  combos: string[][];
  description: LocalizedText;
  note?: LocalizedText;
};

export type ShortcutCategory = {
  id: string;
  titleKey: string;
  blurbKey?: string;
  shortcuts: Shortcut[];
};

export const shortcutCategories: ShortcutCategory[] = [
  {
    id: "app",
    titleKey: "app",
    blurbKey: "appBlurb",
    shortcuts: [
      { id: "openSettings", combos: [["⌘", ","]], description: { en: "Settings", ja: "設定" } },
      { id: "reloadConfiguration", combos: [["⌘", "⇧", ","]], description: { en: "Reload configuration", ja: "構成を再読み込み" } },
      {
        id: "showHideAllWindows",
        combos: [["⌃", "⌥", "⌘", "."]],
        description: { en: "Show/hide all cmux windows", ja: "すべてのcmuxウインドウを表示/非表示" },
        note: { en: "system-wide hotkey", ja: "システム全体のホットキー" },
      },
      { id: "commandPalette", combos: [["⌘", "⇧", "P"]], description: { en: "Command palette", ja: "コマンドパレット" } },
      { id: "newWindow", combos: [["⌘", "⇧", "N"]], description: { en: "New window", ja: "新規ウインドウ" } },
      { id: "closeWindow", combos: [["⌃", "⌘", "W"]], description: { en: "Close window", ja: "ウインドウを閉じる" } },
      { id: "toggleFullScreen", combos: [["⌃", "⌘", "F"]], description: { en: "Toggle full screen", ja: "フルスクリーンを切り替え" } },
      { id: "sendFeedback", combos: [["⌥", "⌘", "F"]], description: { en: "Send feedback", ja: "フィードバックを送信" } },
      {
        id: "reopenPreviousSession",
        combos: [["⌘", "⇧", "O"]],
        description: { en: "Reopen previous session", ja: "前回のセッションを再度開く" },
      },
      { id: "quit", combos: [["⌘", "Q"]], description: { en: "Quit cmux", ja: "cmuxを終了" } },
    ],
  },
  {
    id: "workspaces",
    titleKey: "workspaces",
    blurbKey: "workspacesBlurb",
    shortcuts: [
      { id: "toggleSidebar", combos: [["⌘", "B"]], description: { en: "Toggle sidebar", ja: "サイドバーを切り替え" } },
      { id: "newTab", combos: [["⌘", "N"]], description: { en: "New workspace", ja: "新規ワークスペース" } },
      { id: "openFolder", combos: [["⌘", "O"]], description: { en: "Open folder", ja: "フォルダを開く" } },
      {
        id: "goToWorkspace",
        combos: [["⌘", "P"]],
        description: { en: "Go to workspace", ja: "ワークスペースへ移動" },
        note: { en: "workspace switcher", ja: "ワークスペーススイッチャー" },
      },
      { id: "nextSidebarTab", combos: [["⌃", "⌘", "]"]], description: { en: "Next workspace", ja: "次のワークスペース" } },
      { id: "prevSidebarTab", combos: [["⌃", "⌘", "["]], description: { en: "Previous workspace", ja: "前のワークスペース" } },
      { id: "selectWorkspaceByNumber", combos: [["⌘", "1…9"]], description: { en: "Select workspace 1…9", ja: "ワークスペース1…9を選択" } },
      { id: "renameWorkspace", combos: [["⌘", "⇧", "R"]], description: { en: "Rename workspace", ja: "ワークスペース名を変更" } },
      { id: "editWorkspaceDescription", combos: [["⌥", "⌘", "E"]], description: { en: "Edit workspace description", ja: "ワークスペースの説明を編集" } },
      { id: "focusRightSidebar", combos: [["⌘", "⇧", "E"]], description: { en: "Focus right sidebar", ja: "右サイドバーにフォーカス" } },
      {
        id: "switchRightSidebarMode",
        combos: [["⌃", "1 / 2 / 3 / 4"]],
        description: { en: "Switch Files / Find / Sessions / Feed", ja: "ファイル / 検索 / セッション / フィードを切り替え" },
        note: { en: "when the right sidebar is focused", ja: "右サイドバーにフォーカス中" },
      },
      {
        id: "navigateRightSidebarRows",
        combos: [["J / K"], ["⌃", "N / P"], ["H / L"]],
        description: { en: "Navigate focused sidebar rows", ja: "フォーカス中のサイドバー行を移動" },
        note: {
          en: "In Files, H/L collapse and expand folders. Search starts with /.",
          ja: "ファイルでは H/L でフォルダを折りたたみ/展開します。検索は / で開始します。",
        },
      },
      { id: "closeWorkspace", combos: [["⌘", "⇧", "W"]], description: { en: "Close workspace", ja: "ワークスペースを閉じる" } },
    ],
  },
  {
    id: "surfaces",
    titleKey: "surfaces",
    blurbKey: "surfacesBlurb",
    shortcuts: [
      { id: "newSurface", combos: [["⌘", "T"]], description: { en: "New surface", ja: "新規サーフェス" } },
      { id: "nextSurface", combos: [["⌘", "⇧", "]"]], description: { en: "Next surface", ja: "次のサーフェス" } },
      { id: "prevSurface", combos: [["⌘", "⇧", "["]], description: { en: "Previous surface", ja: "前のサーフェス" } },
      { id: "selectSurfaceByNumber", combos: [["⌃", "1…9"]], description: { en: "Select surface 1…9", ja: "サーフェス1…9を選択" } },
      { id: "renameTab", combos: [["⌘", "R"]], description: { en: "Rename tab", ja: "タブ名を変更" } },
      { id: "closeTab", combos: [["⌘", "W"]], description: { en: "Close tab", ja: "タブを閉じる" } },
      { id: "closeOtherTabsInPane", combos: [["⌥", "⌘", "T"]], description: { en: "Close other tabs in pane", ja: "ペイン内の他のタブを閉じる" } },
      { id: "reopenClosedBrowserPanel", combos: [["⌘", "⇧", "T"]], description: { en: "Reopen closed browser panel", ja: "閉じたブラウザパネルを再度開く" } },
      { id: "toggleTerminalCopyMode", combos: [["⌘", "⇧", "M"]], description: { en: "Toggle terminal copy mode", ja: "ターミナルコピーモードを切り替え" } },
    ],
  },
  {
    id: "split-panes",
    titleKey: "splitPanes",
    shortcuts: [
      { id: "focusLeft", combos: [["⌥", "⌘", "←"]], description: { en: "Focus pane left", ja: "左のペインにフォーカス" } },
      { id: "focusRight", combos: [["⌥", "⌘", "→"]], description: { en: "Focus pane right", ja: "右のペインにフォーカス" } },
      { id: "focusUp", combos: [["⌥", "⌘", "↑"]], description: { en: "Focus pane up", ja: "上のペインにフォーカス" } },
      { id: "focusDown", combos: [["⌥", "⌘", "↓"]], description: { en: "Focus pane down", ja: "下のペインにフォーカス" } },
      { id: "splitRight", combos: [["⌘", "D"]], description: { en: "Split right", ja: "右に分割" } },
      { id: "splitDown", combos: [["⌘", "⇧", "D"]], description: { en: "Split down", ja: "下に分割" } },
      { id: "splitBrowserRight", combos: [["⌥", "⌘", "D"]], description: { en: "Split browser right", ja: "右にブラウザ分割" } },
      { id: "splitBrowserDown", combos: [["⌥", "⌘", "⇧", "D"]], description: { en: "Split browser down", ja: "下にブラウザ分割" } },
      { id: "toggleSplitZoom", combos: [["⌘", "⇧", "↩"]], description: { en: "Toggle pane zoom", ja: "ペインズームを切り替え" } },
    ],
  },
  {
    id: "browser",
    titleKey: "browser",
    shortcuts: [
      { id: "openBrowser", combos: [["⌘", "⇧", "L"]], description: { en: "Open browser", ja: "ブラウザを開く" } },
      { id: "focusBrowserAddressBar", combos: [["⌘", "L"]], description: { en: "Focus address bar", ja: "アドレスバーにフォーカス" } },
      { id: "browserBack", combos: [["⌘", "["]], description: { en: "Back", ja: "戻る" } },
      { id: "browserForward", combos: [["⌘", "]"]], description: { en: "Forward", ja: "進む" } },
      {
        id: "browserReload",
        combos: [["⌘", "R"]],
        description: { en: "Reload page", ja: "ページを再読み込み" },
        note: { en: "focused browser", ja: "フォーカス中のブラウザ" },
      },
      { id: "browserZoomIn", combos: [["⌘", "="]], description: { en: "Zoom in", ja: "拡大" } },
      { id: "browserZoomOut", combos: [["⌘", "-"]], description: { en: "Zoom out", ja: "縮小" } },
      { id: "browserZoomReset", combos: [["⌘", "0"]], description: { en: "Actual size", ja: "実寸表示" } },
      { id: "toggleBrowserDeveloperTools", combos: [["⌥", "⌘", "I"]], description: { en: "Toggle browser developer tools", ja: "ブラウザ開発者ツールを切り替え" } },
      { id: "showBrowserJavaScriptConsole", combos: [["⌥", "⌘", "C"]], description: { en: "Show browser JavaScript console", ja: "ブラウザJavaScriptコンソールを表示" } },
      {
        id: "toggleReactGrab",
        combos: [["⌘", "⇧", "G"]],
        description: { en: "Toggle React Grab", ja: "React Grabを切り替え" },
        note: {
          en: "focused browser, or the only browser pane when a terminal is focused",
          ja: "フォーカス中のブラウザ、またはターミナルにフォーカスがあるときは唯一のブラウザペイン",
        },
      },
    ],
  },
  {
    id: "find",
    titleKey: "find",
    shortcuts: [
      { id: "find", combos: [["⌘", "F"]], description: { en: "Find", ja: "検索" } },
      { id: "findNext", combos: [["⌘", "G"]], description: { en: "Find next", ja: "次を検索" } },
      { id: "findPrevious", combos: [["⌥", "⌘", "G"]], description: { en: "Find previous", ja: "前を検索" } },
      { id: "hideFind", combos: [["⌘", "⇧", "F"]], description: { en: "Hide find bar", ja: "検索バーを隠す" } },
      { id: "useSelectionForFind", combos: [["⌘", "E"]], description: { en: "Use selection for find", ja: "選択範囲で検索" } },
    ],
  },
  {
    id: "notifications",
    titleKey: "notifications",
    shortcuts: [
      { id: "showNotifications", combos: [["⌘", "I"]], description: { en: "Show notifications", ja: "通知を表示" } },
      { id: "jumpToUnread", combos: [["⌘", "⇧", "U"]], description: { en: "Jump to latest unread", ja: "最新の未読へ移動" } },
      { id: "triggerFlash", combos: [["⌘", "⇧", "H"]], description: { en: "Flash focused panel", ja: "フォーカス中のパネルをフラッシュ" } },
    ],
  },
];
