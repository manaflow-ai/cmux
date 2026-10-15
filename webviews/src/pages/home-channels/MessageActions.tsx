// A message's hover card (top end of the row): three quick reactions, Add reaction (the emoji
// popover), Reply in thread, and More (Copy text; Edit and Delete on my own message). It shows on
// hover and on keyboard focus inside the row, and stays while one of its popups is open.
import { useRef, useState } from "react";
import type { EmojiTable } from "../../icon-picker/emojiData";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../ui/Menu";
import { Toolbar, ToolbarButton } from "../../ui/Toolbar";
import type { Strings } from "../shared/i18n";
import { EmojiPicker, loadEmoji } from "./EmojiPicker";
import { HomeIcon } from "./icons";

const QUICK_REACTIONS = ["✅", "👀", "🙌"];

export interface MessageActionsProps {
  strings: Strings;
  canEdit: boolean;
  canDelete: boolean;
  onReact(value: string): void;
  onReply?(): void;
  onEdit(): void;
  onDelete(): void;
  onCopy(): void;
  /** Copies the message's link (`cmux://conversation/<id>/message/<id>`). */
  onCopyLink?(): void;
  /** The Reply label: "Reply in Thread" in the timeline, "Reply" inside a thread. */
  replyLabel?: string;
}

export function MessageActions({
  strings,
  canEdit,
  canDelete,
  onReact,
  onReply,
  onEdit,
  onDelete,
  onCopy,
  onCopyLink,
  replyLabel,
}: MessageActionsProps) {
  const { t, format } = strings;
  const reply = replyLabel ?? t("action.reply");
  const [picker, setPicker] = useState<Element | null>(null);
  const [emoji, setEmoji] = useState<EmojiTable | undefined>();
  const [menu, setMenu] = useState(false);
  const box = useRef<HTMLDivElement | null>(null);
  return (
    <div ref={box} className={`hc-msg-actions${picker || menu ? " pinned" : ""}`}>
      <Toolbar label={t("message.actions")} className="hc-msg-toolbar">
        {QUICK_REACTIONS.map((value) => (
          <ToolbarButton
            key={value}
            label={format("action.reactWith", value)}
            className="hc-tool hc-quick"
            onPress={() => onReact(value)}
          >
            <span aria-hidden="true">{value}</span>
          </ToolbarButton>
        ))}
        <ToolbarButton
          label={t("action.react")}
          className="hc-tool"
          onPress={() => {
            setPicker(box.current);
            loadEmoji().then(setEmoji, () => setPicker(null));
          }}
        >
          <HomeIcon name="addReaction" />
        </ToolbarButton>
        {onReply && (
          <ToolbarButton label={reply} className="hc-tool" onPress={onReply}>
            <HomeIcon name="reply" />
          </ToolbarButton>
        )}
        <Menu open={menu} onOpenChange={setMenu}>
          <MenuButton className="hc-tool ui-toolbar-button" label={t("action.more")} title={t("action.more")}>
            <HomeIcon name="more" />
          </MenuButton>
          <MenuPopup side="bottom" align="end">
            <MenuItem onSelect={onCopy}>{t("action.copy")}</MenuItem>
            {onCopyLink && <MenuItem onSelect={onCopyLink}>{t("action.copyLink")}</MenuItem>}
            {onReply && <MenuItem onSelect={onReply}>{reply}</MenuItem>}
            {(canEdit || canDelete) && <MenuSeparator />}
            {canEdit && <MenuItem onSelect={onEdit}>{t("action.edit")}</MenuItem>}
            {canDelete && (
              <MenuItem className="danger" onSelect={onDelete}>
                {t("action.delete")}
              </MenuItem>
            )}
          </MenuPopup>
        </Menu>
      </Toolbar>
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
  );
}
