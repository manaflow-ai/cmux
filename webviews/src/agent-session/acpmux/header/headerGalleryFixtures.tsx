// l10n-allow-file: gallery fixtures (sample chat actions and banners), not shipped UI.
// Shared by the header width galleries (HeaderWidths, SummaryPlacements): the REAL header as PaneBody
// renders it (header/ChatHeaderStatus, ThreadTitle, ChatSummaryLine, ChatHeaderTools) in a pane of a
// given width, own-row (title beside the summary) or tab-row (the native tab strip's geometry mocked,
// the summary a chip beside the tools).
import { createElement, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { ChatHeaderInlineStatus, ChatHeaderStatus } from "./ChatHeaderStatus";
import { ChatHeaderTools } from "./ChatHeaderTools";
import type { ChatMenuItem } from "./chatHeaderToolsModel";
import { ChatSummaryLine, type ChatSummary } from "./ChatSummaryLine";
import { PanelToggle } from "./PanelToggle";
import { ThreadTitle } from "./ThreadTitle";
import { FORK_ICON } from "../icons/forkIcon";

export type Banner = "none" | "short" | "long";
export type HeaderMode = "ownrow" | "tabrow";

export const BANNERS: Record<Banner, ChatSummary | null> = {
  none: null,
  short: { text: "Tests pass", next: "Open the PR" },
  // The kind in Leo's 2026-11-23 screenshot.
  long: {
    text: "Send-scroll removal underway; ChatGPT login fix in review",
    next: "Verify on nightly and close the issue",
  },
};

export const BANNER_LABEL: Record<Banner, string> = { none: "no banner", short: "short banner", long: "long banner" };

const noop = () => undefined;

const menu = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", shortcutAction: "renameTab", onSelect: noop },
  { key: "pin", label: "Pin", icon: "action.pin", shortcutAction: "palette.toggleTabPin", onSelect: noop },
  "separator",
  { key: "sideChat", label: "New side chat", icon: "agent.chat.new", onSelect: noop },
  { key: "fork", label: "Fork", icon: FORK_ICON, onSelect: noop },
  "separator",
  { key: "archive", label: "Archive", icon: "inbox", onSelect: noop },
  { key: "close", label: "Close", icon: "tab.close", shortcutAction: "closeTab", onSelect: noop },
];

const panelToggle = createElement(PanelToggle, {
  className: "acpmux-session-info-toggle",
  label: "Session Info",
  shown: false,
  onToggle: noop,
});

/** The tools' props ChatHeaderTools.gallery.tsx uses (its `base`), with Changes shown as a chat that edited files has it. */
export function headerToolsProps() {
  return {
    onTerminal: noop,
    onSplitDown: noop,
    onBrowser: noop,
    onSideTabs: noop,
    onFiles: noop,
    hasChanges: true,
    onChanges: noop,
    summary: panelToggle,
    menu,
    onMenuOpen: async () => undefined,
  };
}

export const TAB_ROW_HEIGHT = 28;
export const TAB_ROW_INSET = 8;

/** The tab strip as the native app draws it: tabs from the left, ending where the tools begin. */
function NativeTabStrip({ toolsLeft, title }: { toolsLeft: number; title: string }) {
  return (
    <div
      aria-hidden="true"
      data-native-tab-strip=""
      style={{
        position: "absolute",
        left: 0,
        top: 2,
        height: 24,
        width: Math.max(0, toolsLeft - 4),
        display: "flex",
        gap: 2,
        overflow: "hidden",
        padding: "0 6px",
        boxSizing: "border-box",
        pointerEvents: "none",
        zIndex: "var(--layer-sticky)",
      }}
    >
      {[title, "GitHub"].map((name, index) => (
        <div
          key={name}
          style={{
            flex: "0 1 140px",
            minWidth: 28,
            height: 24,
            padding: "0 8px",
            boxSizing: "border-box",
            display: "flex",
            alignItems: "center",
            borderRadius: 6,
            overflow: "hidden",
            whiteSpace: "nowrap",
            textOverflow: "ellipsis",
            fontSize: 12,
            background: index === 0 ? "var(--ds-color-selection, rgba(127,127,127,.2))" : undefined,
            color: index === 0 ? "var(--agent-text)" : "var(--agent-muted)",
          }}
        >
          {name}
        </div>
      ))}
    </div>
  );
}

/**
 * One real header at `width` px, as PaneBody renders it. Own row: the title and ChatSummaryLine in the status
 * slot. Tab row: no title (the native tab names the chat), the summary a chip before the tools, and the native
 * tab strip drawn over the slot, ending where the tools start.
 */
export function PaneHeader({
  mode,
  width,
  banner,
  title = "Remove send-scroll",
  extraHeaderStyle,
  statusContent,
}: {
  mode: HeaderMode;
  width: number;
  banner: ChatSummary | null;
  title?: string;
  extraHeaderStyle?: CSSProperties;
  /** Replaces the own-row title + summary (the placement mocks). */
  statusContent?: ReactNode;
}) {
  const tools = useRef<HTMLDivElement | null>(null);
  const [toolsLeft, setToolsLeft] = useState(width);
  useLayoutEffect(() => {
    const element = tools.current;
    const header = element?.closest("header");
    if (!element || !header || typeof ResizeObserver === "undefined") return;
    const read = () =>
      setToolsLeft(Math.round(element.getBoundingClientRect().left - header.getBoundingClientRect().left));
    read();
    const observer = new ResizeObserver(read);
    observer.observe(element);
    observer.observe(header);
    return () => observer.disconnect();
  }, [width, mode]);
  const tabRow = mode === "tabrow";
  const shellStyle = {
    width,
    height: TAB_ROW_HEIGHT,
    flex: "none",
    "--acpmux-tab-row-height": `${TAB_ROW_HEIGHT}px`,
    "--acpmux-tab-row-inset": `${TAB_ROW_INSET}px`,
  } as CSSProperties;
  return (
    <section
      className="acpmux-shell"
      data-tab-row={tabRow ? "" : undefined}
      data-header-width={width}
      style={shellStyle}
    >
      <div className="acpmux-stage" style={{ flex: "1 1 0", minWidth: 0, display: "flex", flexDirection: "column" }}>
        <header className="acpmux-header" data-tab-row={tabRow ? "" : undefined} style={extraHeaderStyle}>
          <ChatHeaderStatus status="">
            {!tabRow &&
              (statusContent ?? (
                <span className="acpmux-header-status-content">
                  <ThreadTitle title={title} onRename={noop} />
                  <ChatSummaryLine summary={banner} />
                </span>
              ))}
          </ChatHeaderStatus>
          <div className="acpmux-handoff-header-tools" ref={tools}>
            {tabRow && (
              <ChatHeaderInlineStatus status="">
                <ChatSummaryLine summary={banner} chip />
              </ChatHeaderInlineStatus>
            )}
            <ChatHeaderTools {...headerToolsProps()} />
          </div>
          {tabRow && <NativeTabStrip toolsLeft={toolsLeft} title={title} />}
        </header>
      </div>
    </section>
  );
}
