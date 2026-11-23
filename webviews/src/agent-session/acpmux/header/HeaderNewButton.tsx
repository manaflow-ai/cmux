// The New split button of the chat header's three controls (headerTrio.ts, Debug Settings
// `agentChat.headerControls`). Its face makes the last kind again in one click, so a terminal stays
// one click for whoever makes terminals; the first click ever opens the New Tab page, which offers
// every kind. Its chevron lists every kind, and the row under the pointer previews where it opens:
// a drawing of the pane with the new tab beside the chat, its name and its key.
import { useState } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { HeaderIcon } from "./HeaderIcon";
import { HEADER_ACTIONS } from "./headerActions";
import { menuKeycap } from "./chatHeaderToolsModel";
import { readLastKind, repeatKind, writeLastKind, type NewKind } from "./headerTrio";
import { tooltipProps, useShortcut } from "../shortcuts";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";

const KIND_LABELS: Record<NewKind, StringKey> = {
  terminal: "chatMenu.newTerminal",
  browser: "chatMenu.newBrowser",
  sideChat: "chatMenu.sideChat",
  newTab: "header.newTab",
};

const KIND_ICONS: Record<NewKind, string> = {
  terminal: "terminal",
  browser: "browser",
  sideChat: "agent.chat.new",
  newTab: "action.add",
};

/// The app action whose key a kind's row shows; the side chat and the New Tab page have none.
const KIND_ACTIONS: Partial<Record<NewKind, string>> = {
  terminal: HEADER_ACTIONS.terminal,
  browser: HEADER_ACTIONS.browser,
};

export function HeaderNewButton({
  kinds,
  make,
  initialLast,
  initialOpen = false,
}: {
  /// The kinds this chat can make now, in the menu's order (headerTrio.ts newKinds).
  kinds: readonly NewKind[];
  make: (kind: NewKind) => void;
  /// The gallery's last kind; the app reads the one kept on this Mac.
  initialLast?: NewKind;
  /// The gallery draws the menu open.
  initialOpen?: boolean;
}) {
  const t = useT();
  const [last, setLast] = useState<NewKind | undefined>(() => initialLast ?? readLastKind());
  const [open, setOpen] = useState(initialOpen);
  const again = repeatKind(last, kinds);
  const [previewed, setPreviewed] = useState<NewKind>(again);
  const terminalKey = useShortcut(HEADER_ACTIONS.terminal);
  const browserKey = useShortcut(HEADER_ACTIONS.browser);
  const keys: Partial<Record<NewKind, string | undefined>> = {
    terminal: menuKeycap(terminalKey),
    browser: menuKeycap(browserKey),
  };
  const run = (kind: NewKind) => {
    setLast(kind);
    writeLastKind(kind);
    make(kind);
  };
  const label = (kind: NewKind) => t(KIND_LABELS[kind]);
  return (
    <div className="acpmux-header-new" data-header-new={again}>
      <button
        type="button"
        className="acpmux-header-tool acpmux-header-new-face"
        aria-label={label(again)}
        {...tooltipProps(label(again), KIND_ACTIONS[again] ? keys[again] : undefined)}
        onClick={() => run(again)}
      >
        <HeaderIcon name="action.add" size={16} />
      </button>
      <Menu
        open={open}
        onOpenChange={(next) => {
          if (next) setPreviewed(again);
          setOpen(next);
        }}
      >
        <MenuButton className="acpmux-header-tool acpmux-header-new-more" label={t("header.newMenu")}>
          <Icon name="disclosure.expanded" size={12} />
        </MenuButton>
        <MenuPopup className="acpmux-chat-menu-popover acpmux-header-new-popover" align="end">
          <NewPreview kind={previewed} label={label(previewed)} keycap={keys[previewed]} />
          {kinds.map((kind) => (
            <MenuItem
              key={kind}
              data-value={kind}
              className="acpmux-chat-menu-item"
              // The arrow keys move the highlight and focus with it, so the preview follows them as well as the
              // pointer. Only the highlighted row's focus counts: the menu's own first focus as it opens lands on
              // a row the pointer may already have left.
              onPointerEnter={() => setPreviewed(kind)}
              onFocus={(event) => {
                if (event.currentTarget.hasAttribute("data-highlighted")) setPreviewed(kind);
              }}
              onSelect={() => run(kind)}
            >
              <Icon name={KIND_ICONS[kind]} size={14} />
              <span className="acpmux-chat-menu-label">{label(kind)}</span>
              {keys[kind] && <kbd className="acpmux-chat-menu-key">{keys[kind]}</kbd>}
            </MenuItem>
          ))}
        </MenuPopup>
      </Menu>
    </div>
  );
}

/// Where the kind opens, drawn: the chat on the left and the new tab on its right, as the pane will be.
function NewPreview({ kind, label, keycap }: { kind: NewKind; label: string; keycap?: string }) {
  const t = useT();
  return (
    <div className="acpmux-header-new-preview" data-new-preview={kind} aria-hidden="true">
      <div className="acpmux-header-new-preview-pane">
        <span className="acpmux-header-new-preview-chat">
          <i />
          <i />
        </span>
        <span className="acpmux-header-new-preview-tab">
          <Icon name={KIND_ICONS[kind]} size={14} />
        </span>
      </div>
      <div className="acpmux-header-new-preview-text">
        <span className="acpmux-header-new-preview-name">{label}</span>
        {keycap && <kbd className="acpmux-chat-menu-key">{keycap}</kbd>}
      </div>
      {/* Both texts share one cell, the other one hidden, so the preview keeps the taller one's height and
          the rows under it never move as the pointer goes from row to row. */}
      <div className="acpmux-header-new-preview-detail">
        <span data-shown={kind === "newTab" || undefined}>{t("header.newPreviewTab")}</span>
        <span data-shown={kind !== "newTab" || undefined}>{t("header.newPreviewBeside")}</span>
      </div>
    </div>
  );
}
