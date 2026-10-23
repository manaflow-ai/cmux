// A message's actions. A right-click on the row offers them all: three quick reactions, Add Reaction
// (the emoji popover), Reply in Thread, Copy, and Edit and Delete on my own message. The hover card
// at the row's top end shows on hover and on keyboard focus inside the row, and stays while one of
// its popups is open: More alone, with every item (Leo dogfood 2026-10-13: hover buttons
// everywhere); or, in the `hover-actions` experiment's "all" arm, the quick reactions, Add reaction,
// Reply in thread and More (Copy, Reply, Edit, Delete).
import { Fragment, type ReactNode, useRef, useState } from "react";
import type { EmojiTable } from "../../icon-picker/emojiData";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { experimentArm } from "../../experiments/experiment";
import { hoverActions } from "../../ui/hoverActions.experiment";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../ui/Menu";
import { Toolbar, ToolbarButton } from "../../ui/Toolbar";
import type { Strings } from "../shared/i18n";
import { EmojiPicker, loadEmoji } from "./EmojiPicker";
import { HomeIcon } from "./icons";

const QUICK_REACTIONS = ["✅", "👀", "🙌"];

export interface MessageActionsProps {
  /** False while the message is retracted or edited: no card, and a right-click keeps the page's. */
  active: boolean;
  strings: Strings;
  canEdit: boolean;
  canDelete: boolean;
  onReact(value: string): void;
  onReply?(): void;
  onEdit(): void;
  onDelete(): void;
  onCopy(): void;
  /** The row's content: a right-click on it opens the same items as More. */
  children: ReactNode;
  /** Copies the message's link (`cmux://conversation/<id>/message/<id>`). */
  onCopyLink?(): void;
  /** The Reply label: "Reply in Thread" in the timeline, "Reply" inside a thread. */
  replyLabel?: string;
}

export function MessageActions({
  active,
  strings,
  canEdit,
  canDelete,
  onReact,
  onReply,
  onEdit,
  onDelete,
  onCopy,
  children,
  onCopyLink,
  replyLabel,
}: MessageActionsProps) {
  const { t, format } = strings;
  const reply = replyLabel ?? t("action.reply");
  const [picker, setPicker] = useState<Element | null>(null);
  const [emoji, setEmoji] = useState<EmojiTable | undefined>();
  const [menu, setMenu] = useState(false);
  const box = useRef<HTMLDivElement | null>(null);
  const openPicker = () => {
    setPicker(box.current);
    loadEmoji().then(setEmoji, () => setPicker(null));
  };
  const items: ContextMenuItem[] = [
    ...QUICK_REACTIONS.map((value) => ({
      id: `react-${value}`,
      label: format("action.reactWith", value),
      onSelect: () => onReact(value),
    })),
    { id: "react", label: `${t("action.react")}…`, onSelect: openPicker },
    ...(onReply ? [{ id: "reply", label: reply, onSelect: onReply, separatorBefore: true }] : []),
    { id: "copy", label: t("action.copy"), onSelect: onCopy, separatorBefore: !onReply },
    ...(onCopyLink ? [{ id: "copyLink", label: t("action.copyLink"), onSelect: onCopyLink }] : []),
    ...(canEdit ? [{ id: "edit", label: t("action.edit"), onSelect: onEdit, separatorBefore: true }] : []),
    ...(canDelete
      ? [{ id: "delete", label: t("action.delete"), onSelect: onDelete, destructive: true, separatorBefore: !canEdit }]
      : []),
  ];
  const one = experimentArm(hoverActions) === "one";
  // The card's More: every item in the "one" arm, else what the card's own buttons do not show.
  const byId = (id: string) =>
    items.filter((item) => item.id === id).map((item) => ({ ...item, separatorBefore: false }));
  const more = one
    ? items
    : [
        ...byId("copy"),
        ...byId("copyLink"),
        ...byId("reply"),
        ...items.filter((item) => item.id === "edit" || item.id === "delete"),
      ];
  const moreMenu = (
    <Menu open={menu} onOpenChange={setMenu}>
      <MenuButton
        className={one ? "hc-tool hc-msg-more" : "hc-tool ui-toolbar-button"}
        label={one ? t("message.actions") : t("action.more")}
      >
        <HomeIcon name="more" />
      </MenuButton>
      <MenuPopup side="bottom" align="end">
        {more.map((item, index) => (
          <Fragment key={item.id}>
            {index > 0 && item.separatorBefore && <MenuSeparator />}
            <MenuItem className={item.destructive ? "danger" : undefined} onSelect={item.onSelect}>
              {item.label}
            </MenuItem>
          </Fragment>
        ))}
      </MenuPopup>
    </Menu>
  );
  return (
    <>
      {/* A link keeps the page's own menu (Copy Link, Open Link). */}
      <ContextMenu className="hc-msg-menu-host" items={active ? items : []} targets="own" ignore="a[href]">
        {children}
      </ContextMenu>
      {active && (
        <div ref={box} className={`hc-msg-actions${picker || menu ? " pinned" : ""}`}>
          {one ? (
            moreMenu
          ) : (
            <Toolbar label={t("message.actions")} className="hc-msg-toolbar">
              {QUICK_REACTIONS.map((value) => (
                <ToolbarButton
                  key={value}
                  label={format("action.reactWith", value)}
                  tooltip={false}
                  className="hc-tool hc-quick"
                  onPress={() => onReact(value)}
                >
                  <span aria-hidden="true">{value}</span>
                </ToolbarButton>
              ))}
              <ToolbarButton label={t("action.react")} className="hc-tool" onPress={openPicker}>
                <HomeIcon name="addReaction" />
              </ToolbarButton>
              {onReply && (
                <ToolbarButton label={reply} className="hc-tool" onPress={onReply}>
                  <HomeIcon name="reply" />
                </ToolbarButton>
              )}
              {moreMenu}
            </Toolbar>
          )}
          {picker && (
            <EmojiPicker
              anchor={picker}
              emoji={emoji}
              strings={strings}
              onPick={(value) => {
                setPicker(null);
                onReact(value);
              }}
              onClose={() => setPicker(null)}
            />
          )}
        </div>
      )}
    </>
  );
}
