"use client";

import { useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";

type LocalizedText = {
  en: string;
  ja: string;
};

type Shortcut = {
  id: string;
  combos: string[][];
  description: LocalizedText;
  note?: LocalizedText;
};

type ShortcutCategory = {
  id: string;
  titleKey: string;
  blurbKey?: string;
  shortcuts: Shortcut[];
};

const CATEGORIES: ShortcutCategory[] = [
  {
    id: "app",
    titleKey: "app",
    blurbKey: "appBlurb",
    shortcuts: [
      { id: "openSettings", combos: [["⌘", ","]], description: { en: "Settings", ja: "設定" } },
      { id: "reloadConfiguration", combos: [["⌘", "⇧", ","]], description: { en: "Reload configuration", ja: "構成を再読み込み" } },
      { id: "commandPalette", combos: [["⌘", "⇧", "P"]], description: { en: "Command palette", ja: "コマンドパレット" } },
      { id: "newWindow", combos: [["⌘", "⇧", "N"]], description: { en: "New window", ja: "新規ウインドウ" } },
      { id: "closeWindow", combos: [["⌃", "⌘", "W"]], description: { en: "Close window", ja: "ウインドウを閉じる" } },
      { id: "toggleFullScreen", combos: [["⌃", "⌘", "F"]], description: { en: "Toggle full screen", ja: "フルスクリーンを切り替え" } },
      { id: "sendFeedback", combos: [["⌥", "⌘", "F"]], description: { en: "Send feedback", ja: "フィードバックを送信" } },
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
        combos: [["⌥", "⌘", "G"]],
        description: { en: "Toggle React Grab", ja: "React Grabを切り替え" },
        note: { en: "focused browser", ja: "フォーカス中のブラウザ" },
      },
    ],
  },
  {
    id: "find",
    titleKey: "find",
    shortcuts: [
      { id: "find", combos: [["⌘", "F"]], description: { en: "Find", ja: "検索" } },
      { id: "findNext", combos: [["⌘", "G"]], description: { en: "Find next", ja: "次を検索" } },
      { id: "findPrevious", combos: [["⌘", "⇧", "G"]], description: { en: "Find previous", ja: "前を検索" } },
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

function localizedText(text: LocalizedText, locale: string) {
  return locale.startsWith("ja") ? text.ja : text.en;
}

function normalize(s: string) {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

function comboToText(combo: string[]) {
  return combo.join(" ");
}

function KeyCombo({ combo }: { combo: string[] }) {
  return (
    <span className="inline-flex items-center">
      {combo.map((k, idx) => (
        <span key={`${k}-${idx}`} className="inline-flex items-center">
          <kbd>{k}</kbd>
          {idx < combo.length - 1 && (
            <span className="text-muted/30 mx-[3px] select-none font-mono text-[10px]">
              +
            </span>
          )}
        </span>
      ))}
    </span>
  );
}

function ShortcutRow({ shortcut, locale }: { shortcut: Shortcut; locale: string }) {
  const description = localizedText(shortcut.description, locale);
  const note = shortcut.note ? localizedText(shortcut.note, locale) : undefined;

  return (
    <div className="flex items-center justify-between gap-4 px-4 py-[11px] transition-colors hover:bg-foreground/[0.025]">
      <div className="min-w-0">
        <span className="text-[14px] text-foreground/90">{description}</span>
        {note && <span className="ml-2 text-[12px] text-muted/50">{note}</span>}
      </div>
      <div className="flex shrink-0 items-center gap-3">
        {shortcut.combos.map((combo, idx) => (
          <span key={`${shortcut.id}-combo-${idx}`} className="inline-flex items-center">
            {idx > 0 && (
              <span className="mr-3 select-none font-mono text-[11px] text-muted/30">
                /
              </span>
            )}
            <KeyCombo combo={combo} />
          </span>
        ))}
      </div>
    </div>
  );
}

export function KeyboardShortcuts() {
  const [query, setQuery] = useState("");
  const locale = useLocale();
  const t = useTranslations("docs.keyboardShortcuts");

  const trimmedQuery = query.trim();

  const filtered = useMemo(() => {
    const q = normalize(query);
    if (!q) return CATEGORIES;
    return CATEGORIES.map((cat) => ({
      ...cat,
      shortcuts: cat.shortcuts.filter((shortcut) => {
        const catTitle = t(`cat.${cat.titleKey}`);
        const description = localizedText(shortcut.description, locale);
        const note = shortcut.note ? localizedText(shortcut.note, locale) : "";
        const combos = shortcut.combos.map(comboToText).join(" ");
        return normalize(`${catTitle} ${combos} ${description} ${note}`).includes(q);
      }),
    })).filter((cat) => cat.shortcuts.length > 0);
  }, [locale, query, t]);

  return (
    <div className="mb-12 mt-2">
      <div className="relative mb-8">
        <div className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted/40">
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.3-4.3" />
          </svg>
        </div>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t("searchPlaceholder")}
          className="w-full rounded-lg border border-border bg-transparent py-1.5 pl-9 pr-3 text-[13px] transition-colors placeholder:text-muted/40 focus:border-foreground/20 focus:outline-none"
          aria-label={t("searchLabel")}
        />
      </div>

      {!trimmedQuery && (
        <nav className="mb-10 flex flex-wrap items-center gap-y-2">
          {CATEGORIES.map((cat, idx) => (
            <span key={cat.id} className="inline-flex items-center">
              <a
                href={`#${cat.id}`}
                className="text-[13px] text-muted transition-colors hover:text-foreground"
              >
                {t(`cat.${cat.titleKey}`)}
              </a>
              {idx < CATEGORIES.length - 1 && (
                <span className="mx-2.5 select-none text-[10px] text-border">
                  ·
                </span>
              )}
            </span>
          ))}
        </nav>
      )}

      {filtered.length === 0 ? (
        <div className="py-16 text-center">
          <p className="text-[14px] text-muted/70">{t("noResults")}</p>
          <p className="mt-1.5 text-[13px] text-muted/40">{t("noResultsHint")}</p>
        </div>
      ) : (
        <div className="space-y-10">
          {filtered.map((cat) => (
            <section key={cat.id} id={cat.id} className="scroll-mt-20">
              <div className="mb-3">
                <div className="text-[13px] font-medium text-muted/60">
                  {t(`cat.${cat.titleKey}`)}
                </div>
                {cat.blurbKey && (
                  <p className="mt-1 text-[13px] text-muted/50">{t(`cat.${cat.blurbKey}`)}</p>
                )}
              </div>
              <div className="overflow-hidden rounded-xl border border-border">
                <div className="divide-y divide-border/60">
                  {cat.shortcuts.map((shortcut) => (
                    <ShortcutRow key={shortcut.id} shortcut={shortcut} locale={locale} />
                  ))}
                </div>
              </div>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
