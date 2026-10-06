// The chat header's top right, after the Codex app's: Changes with the last turn's counts, which
// opens the changes view beside the transcript; Terminal and Browser, which split the pane in the
// chat's folder; and the "..." chat menu. Every control renders from the first frame at its final
// size; data fills in place.
import React, { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Counts } from "../changes/Counts";
import { usePopover } from "../summary/usePopover";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useShortcut, withShortcut } from "../shortcuts";
import { useUiAnchor } from "../../../ui/anchor";

/// The app actions the header runs on its tab (CmuxNextAgentPane AgentPaneModel.headerActions).
export const HEADER_ACTIONS = {
  terminal: "splitRight",
  browser: "splitBrowserRight",
  rename: "renameTab",
  pin: "palette.toggleTabPin",
  moveRight: "moveSurfaceToPaneRight",
  newWorkspace: "palette.moveTabToNewWorkspace",
  close: "closeTab",
} as const;

export type ChatMenuItem =
  | "separator"
  | {
      key: string;
      label: string;
      icon: string;
      /// An app action id whose keycap the row shows.
      shortcutAction?: string;
      disabled?: boolean;
      onSelect?: () => void;
      children?: { key: string; label: string; onSelect: () => void }[];
    };

export function ChatHeaderTools({
  changes,
  changesOpen,
  onChanges,
  onTerminal,
  onBrowser,
  summary,
  menu,
  onMenuOpen,
  expand,
  onExpanded,
}: {
  /// The last turn that edited files, with its counts; undefined before any edit.
  changes?: { additions: number; deletions: number };
  changesOpen: boolean;
  onChanges: () => void;
  onTerminal: () => void;
  onBrowser: () => void;
  summary: ReactNode;
  /// The menu's rows, read when it opens.
  menu: () => ChatMenuItem[];
  /// Runs before the menu opens; the menu shows once it settles.
  onMenuOpen?: () => Promise<unknown>;
  /// A row with children to show open (the palette's Continue in…); `onExpanded` clears it.
  expand?: string;
  onExpanded?: () => void;
}) {
  const t = useT();
  const terminalKey = useShortcut(HEADER_ACTIONS.terminal);
  const browserKey = useShortcut(HEADER_ACTIONS.browser);
  return (
    <div className="acpmux-header-tools">
      <button
        type="button"
        className="acpmux-header-changes"
        aria-pressed={changesOpen}
        aria-label={t("header.changes")}
        title={t("header.changes")}
        disabled={!changes}
        onClick={onChanges}
      >
        <Icon name="diff.file" size={15} />
        <Counts additions={changes?.additions ?? 0} deletions={changes?.deletions ?? 0} />
      </button>
      <button
        type="button"
        className="acpmux-header-tool"
        aria-label={t("header.terminal")}
        title={withShortcut(t("header.terminal"), terminalKey)}
        onClick={onTerminal}
      >
        <Icon name="terminal" size={15} />
      </button>
      <button
        type="button"
        className="acpmux-header-tool"
        aria-label={t("header.browser")}
        title={withShortcut(t("header.browser"), browserKey)}
        onClick={onBrowser}
      >
        <Icon name="browser" size={15} />
      </button>
      {summary}
      <ChatMenu items={menu} onOpen={onMenuOpen} expand={expand} onExpanded={onExpanded} />
    </div>
  );
}

function ChatMenu({
  items,
  onOpen,
  expand,
  onExpanded,
}: {
  items: () => ChatMenuItem[];
  onOpen?: () => Promise<unknown>;
  expand?: string;
  onExpanded?: () => void;
}) {
  const t = useT();
  const { open, setOpen, button, popover } = usePopover();
  const [rows, setRows] = useState<ChatMenuItem[]>([]);
  const [expanded, setExpanded] = useState<string>();
  const opening = useRef(0);
  const popoverStyle = useUiAnchor(button, popover, open, { side: "below", align: "end" });
  const show = (row?: string) => {
    if (open && !row) return setOpen(false);
    const generation = ++opening.current;
    const ready = () => {
      if (generation !== opening.current) return;
      setRows(items());
      setExpanded(row);
      setOpen(true);
    };
    if (!onOpen) return ready();
    // The menu's labels read the tab's state; a host that does not answer quickly gets the rows anyway.
    const timeout = new Promise((resolve) => window.setTimeout(resolve, 150));
    void Promise.race([onOpen().catch(() => undefined), timeout]).then(ready);
  };
  const showRef = useRef(show);
  showRef.current = show;
  useEffect(() => {
    if (!expand) return;
    showRef.current(expand);
    onExpanded?.();
  }, [expand, onExpanded]);
  const choose = (onSelect?: () => void) => {
    setOpen(false);
    button.current?.focus();
    onSelect?.();
  };
  useLayoutEffect(() => {
    if (!open) return;
    const menu = popover.current;
    (
      menu?.querySelector<HTMLElement>("[aria-expanded=true] + [role=menuitem]") ??
      menu?.querySelector<HTMLElement>("[role=menuitem]:not([aria-disabled=true])")
    )?.focus();
  }, [open, expanded, popover]);
  return (
    <span className="acpmux-chat-menu">
      <button
        ref={button}
        type="button"
        className="acpmux-header-tool"
        aria-label={t("chatMenu.open")}
        title={t("chatMenu.open")}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => show()}
      >
        <Icon name="action.more" size={15} />
      </button>
      {open && (
        <dialog
          ref={popover}
          open
          className="acpmux-chat-menu-popover"
          aria-label={t("chatMenu.open")}
          style={popoverStyle}
        >
          <div
            role="menu"
            tabIndex={-1}
            aria-label={t("chatMenu.open")}
            onKeyDown={(event) => {
              if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
              event.preventDefault();
              const all = [
                ...(popover.current?.querySelectorAll<HTMLElement>("[role=menuitem]:not([aria-disabled=true])") ?? []),
              ];
              const index = all.indexOf(document.activeElement as HTMLElement);
              all[(index + (event.key === "ArrowDown" ? 1 : -1) + all.length) % all.length]?.focus();
            }}
          >
            {rows.map((row, index) =>
              row === "separator" ? (
                // oxlint-disable-next-line react/no-array-index-key
                <hr key={`separator-${index}`} className="acpmux-chat-menu-separator" />
              ) : (
                <React.Fragment key={row.key}>
                  <MenuItem
                    item={row}
                    expanded={expanded === row.key}
                    onSelect={() =>
                      row.children
                        ? setExpanded((current) => (current === row.key ? undefined : row.key))
                        : choose(row.onSelect)
                    }
                  />
                  {expanded === row.key &&
                    row.children?.map((child) => (
                      <button
                        key={child.key}
                        type="button"
                        role="menuitem"
                        tabIndex={-1}
                        className="acpmux-chat-menu-item acpmux-chat-menu-child"
                        onClick={() => choose(child.onSelect)}
                      >
                        <span className="acpmux-chat-menu-label">{child.label}</span>
                      </button>
                    ))}
                </React.Fragment>
              ),
            )}
          </div>
        </dialog>
      )}
    </span>
  );
}

function MenuItem({
  item,
  expanded,
  onSelect,
}: {
  item: Exclude<ChatMenuItem, "separator">;
  expanded: boolean;
  onSelect: () => void;
}) {
  const shortcut = useShortcut(item.shortcutAction ?? "");
  return (
    <button
      type="button"
      role="menuitem"
      tabIndex={-1}
      className="acpmux-chat-menu-item"
      aria-disabled={item.disabled || undefined}
      aria-haspopup={item.children ? "menu" : undefined}
      aria-expanded={item.children ? expanded : undefined}
      onClick={() => {
        if (!item.disabled) onSelect();
      }}
    >
      <Icon name={item.icon} size={15} />
      <span className="acpmux-chat-menu-label">{item.label}</span>
      {shortcut && <kbd className="acpmux-chat-menu-key">{shortcut}</kbd>}
      {item.children && <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />}
    </button>
  );
}
