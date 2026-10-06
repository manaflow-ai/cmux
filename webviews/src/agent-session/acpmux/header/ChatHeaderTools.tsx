// The chat header's top right, after the Codex app's: Changes with the last turn's counts, which
// opens the changes view beside the transcript; Terminal and Browser, which split the pane in the
// chat's folder; and the "..." chat menu. Every control renders from the first frame at its final
// size; data fills in place.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Counts } from "../changes/Counts";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useShortcut, withShortcut } from "../shortcuts";
import { registerPicker } from "../pickerOpeners";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator, Submenu } from "../../../ui/Menu";

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
  tabTools = true,
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
  /// Terminal and Browser split the chat's tab; Quick Chat's panel has none.
  tabTools?: boolean;
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
      {tabTools && (
        <>
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
        </>
      )}
      {summary}
      <ChatMenu
        items={menu}
        disabled={menu().length === 0}
        onOpen={onMenuOpen}
        expand={expand}
        onExpanded={onExpanded}
      />
    </div>
  );
}

function ChatMenu({
  items,
  disabled,
  onOpen,
  expand,
  onExpanded,
}: {
  items: () => ChatMenuItem[];
  /// No rows yet (Quick Chat before its session): the button stays, disabled.
  disabled?: boolean;
  onOpen?: () => Promise<unknown>;
  expand?: string;
  onExpanded?: () => void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<ChatMenuItem[]>([]);
  // Set when the palette asks for one row's children (Continue in…): the menu lists only those.
  const [only, setOnly] = useState<string>();
  const opening = useRef(0);
  const show = (row?: string) => {
    const generation = ++opening.current;
    const ready = () => {
      if (generation !== opening.current) return;
      setRows(items());
      setOnly(row);
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
  // Automation and captures open it by its label, as a click does (see pickerOpeners.ts).
  const label = t("chatMenu.open");
  useEffect(() => registerPicker(label, () => showRef.current()), [label]);
  const onOpenChange = (next: boolean) => {
    if (next) return show();
    opening.current++;
    setOpen(false);
  };
  const focused = only ? rows.find((row) => row !== "separator" && row.key === only) : undefined;
  const children = focused && focused !== "separator" ? focused.children : undefined;
  return (
    <Menu open={open} onOpenChange={onOpenChange}>
      <MenuButton className="acpmux-header-tool" label={label} disabled={disabled}>
        <Icon name="action.more" size={15} />
      </MenuButton>
      <MenuPopup className="acpmux-chat-menu-popover" align="end">
        {children
          ? children.map((child) => (
              <MenuItem key={child.key} className="acpmux-chat-menu-item" onSelect={child.onSelect}>
                <span className="acpmux-chat-menu-label">{child.label}</span>
              </MenuItem>
            ))
          : rows.map((row, index) =>
              row === "separator" ? (
                // oxlint-disable-next-line react/no-array-index-key
                <MenuSeparator key={`separator-${index}`} />
              ) : row.children ? (
                <Submenu
                  key={row.key}
                  className="acpmux-chat-menu-item"
                  popupClassName="acpmux-chat-menu-popover"
                  disabled={row.disabled}
                  label={
                    <>
                      <Icon name={row.icon} size={15} />
                      <span className="acpmux-chat-menu-label">{row.label}</span>
                    </>
                  }
                >
                  {row.children.map((child) => (
                    <MenuItem key={child.key} className="acpmux-chat-menu-item" onSelect={child.onSelect}>
                      <span className="acpmux-chat-menu-label">{child.label}</span>
                    </MenuItem>
                  ))}
                </Submenu>
              ) : (
                <ChatMenuRow key={row.key} item={row} />
              ),
            )}
      </MenuPopup>
    </Menu>
  );
}

function ChatMenuRow({ item }: { item: Exclude<ChatMenuItem, "separator"> }) {
  const shortcut = useShortcut(item.shortcutAction ?? "");
  return (
    <MenuItem className="acpmux-chat-menu-item" disabled={item.disabled} onSelect={item.onSelect}>
      <Icon name={item.icon} size={15} />
      <span className="acpmux-chat-menu-label">{item.label}</span>
      {shortcut && <kbd className="acpmux-chat-menu-key">{shortcut}</kbd>}
    </MenuItem>
  );
}
