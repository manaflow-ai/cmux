// Stable header chrome: edits first, split tools second, then summary and the tab action menu.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useShortcut, withShortcut } from "../shortcuts";
import { registerPicker } from "../pickerOpeners";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator, Submenu } from "../../../ui/Menu";

const toolClass =
  "acpmux-header-tool flex! h-7! w-7 shrink-0 items-center justify-center rounded-md! border-0! bg-transparent! p-0! text-muted! enabled:hover:bg-hover! enabled:hover:text-fg! data-[popup-open]:bg-hover! data-[popup-open]:text-fg! disabled:text-dim! focus-visible:outline focus-visible:outline-fg! focus-visible:outline-offset-2";
const popupClass =
  "acpmux-chat-menu-popover box-border w-[264px] max-w-[calc(100vw-16px)] max-h-[min(540px,70vh)] overflow-auto rounded-xl! border-0! bg-menu! p-1.5! text-control text-fg! shadow-menu! outline-none select-none animate-none! [&>.ui-separator]:mx-2.5 [&>.ui-separator]:my-1.5 [&>.ui-separator]:h-px [&>.ui-separator]:bg-edge";
const rowClass =
  "acpmux-chat-menu-item box-border flex min-h-8 h-auto! w-full items-center gap-2.5! rounded-md! px-2.5! py-1.5! text-fg! outline-none data-[highlighted]:bg-hover! data-[popup-open]:bg-hover! data-[disabled]:text-dim! [&>svg]:shrink-0 [&>svg]:text-muted";
const labelClass = "acpmux-chat-menu-label min-w-0 flex-1 whitespace-normal wrap-anywhere";

/// The app actions the header runs on its tab (CmuxNextAgentPane AgentPaneModel.headerActions).
export const HEADER_ACTIONS = {
  terminal: "splitRight",
  browser: "splitBrowserRight",
  rename: "renameTab",
  pin: "palette.toggleTabPin",
  moveRight: "moveSurfaceToPaneRight",
  newWorkspace: "palette.moveTabToNewWorkspace",
  newWindow: "tab.moveToNewWindow",
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
  const changesLabel = changes
    ? `${t("header.changes")}: +${changes.additions} -${changes.deletions}`
    : t("header.changes");
  return (
    <div className="acpmux-header-tools flex shrink-0 items-center gap-0.5 text-fg">
      <button
        type="button"
        className="acpmux-header-changes me-1.5 inline-flex h-7 w-[132px] shrink-0 items-center justify-center gap-1.5 rounded-md border border-solid border-edge bg-transparent px-2 text-detail text-fg enabled:hover:bg-hover aria-pressed:bg-hover disabled:text-dim focus-visible:outline focus-visible:outline-fg focus-visible:outline-offset-2"
        aria-pressed={changesOpen}
        aria-label={changesLabel}
        title={t("header.changes")}
        disabled={!changes}
        onClick={onChanges}
      >
        <Icon name="diff.file" size={15} />
        <span className="acpmux-header-changes-label font-medium">{t("header.changes")}</span>
        <span aria-hidden="true" className="inline-flex gap-1.5 font-medium tabular-nums" dir="ltr">
          <span className="min-w-[3ch] text-end text-(--acpmux-add)">{changes ? `+${changes.additions}` : ""}</span>
          <span className="min-w-[2ch] text-end text-(--acpmux-del)">{changes ? `-${changes.deletions}` : ""}</span>
        </span>
      </button>
      {tabTools && (
        <>
          <button
            type="button"
            className={toolClass}
            aria-label={t("header.terminal")}
            title={withShortcut(t("header.terminal"), terminalKey)}
            onClick={onTerminal}
          >
            <Icon name="terminal" size={15} />
          </button>
          <button
            type="button"
            className={toolClass}
            aria-label={t("header.browser")}
            title={withShortcut(t("header.browser"), browserKey)}
            onClick={onBrowser}
          >
            <Icon name="browser" size={15} />
          </button>
        </>
      )}
      <span aria-hidden="true" className="mx-1 h-3.5 w-px shrink-0 bg-edge" />
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
      <MenuButton className={toolClass} label={label} disabled={disabled}>
        <Icon name="action.more" size={15} />
      </MenuButton>
      <MenuPopup className={popupClass} align="end">
        {children
          ? children.map((child) => (
              <MenuItem key={child.key} className={rowClass} onSelect={child.onSelect}>
                <span className={labelClass}>{child.label}</span>
              </MenuItem>
            ))
          : rows.map((row, index) =>
              row === "separator" ? (
                // oxlint-disable-next-line react/no-array-index-key
                <MenuSeparator key={`separator-${index}`} />
              ) : row.children ? (
                <Submenu
                  key={row.key}
                  className={rowClass}
                  popupClassName={popupClass}
                  disabled={row.disabled}
                  label={
                    <>
                      <Icon name={row.icon} size={15} />
                      <span className={labelClass}>{row.label}</span>
                    </>
                  }
                >
                  {row.children.map((child) => (
                    <MenuItem key={child.key} className={rowClass} onSelect={child.onSelect}>
                      <span className={labelClass}>{child.label}</span>
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
    <MenuItem className={rowClass} disabled={item.disabled} onSelect={item.onSelect}>
      <Icon name={item.icon} size={15} />
      <span className={labelClass}>{item.label}</span>
      {shortcut && <kbd className="acpmux-chat-menu-key shrink-0 font-sans text-detail text-muted">{shortcut}</kbd>}
    </MenuItem>
  );
}
