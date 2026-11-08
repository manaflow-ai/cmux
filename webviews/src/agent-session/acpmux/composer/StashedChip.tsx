// The Stashed chip in the composer's quiet row (composer/draftStash.ts): while the chat holds a
// stashed draft it names how many, and its menu lists them, newest first; a pick brings that one
// back (before a draft typed meanwhile). It stands in the row's free middle,
// as the machine link does, so the mode, the model and the ring never move when it comes or goes:
// it is always drawn and opens from no width (`data-shown`), in one frame under the motion gate.
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useT } from "../i18n";
import { stashPreview, type StashedDraft } from "./draftStash";
import "./stashedChip.css";

export function StashedChip({
  drafts,
  chat,
  onRestore,
}: {
  drafts: readonly StashedDraft[];
  /// The chat the stack is of: a switch shows the new one's at once.
  chat: string;
  onRestore(id: string): unknown;
}) {
  const t = useT();
  const shown = drafts.length > 0;
  return (
    <span className="acpmux-stash" data-shown={shown || undefined} data-chat={chat} aria-hidden={!shown || undefined}>
      <span className="acpmux-stash-fold">
        <Menu>
          <MenuButton
            className="acpmux-picker-button acpmux-stash-button"
            label={t("composer.stashMenuTitle")}
            title={t("composer.stashChipHint")}
            data-menu="stashed-drafts"
            aria-haspopup="menu"
            disabled={!shown}
          >
            <StashGlyph />
            <span className="acpmux-stash-count">{drafts.length}</span>
          </MenuButton>
          <MenuPopup side="top" align="start" className="acpmux-stash-menu" label={t("composer.stashMenuTitle")}>
            <MenuGroup label={t("composer.stashMenuTitle")}>
              {drafts.map((draft, index) => (
                <MenuItem
                  key={draft.id}
                  data-value={draft.id}
                  shortcut={index === 0 ? "⌃S" : undefined}
                  onSelect={() => onRestore(draft.id)}
                >
                  <span className="acpmux-stash-row">
                    <span className="acpmux-stash-preview">
                      {stashPreview(draft) || t("composer.stashAttachmentsOnly")}
                    </span>
                    {draft.attachments.length > 0 && (
                      <span className="acpmux-stash-files" aria-hidden="true">
                        +{draft.attachments.length}
                      </span>
                    )}
                  </span>
                </MenuItem>
              ))}
            </MenuGroup>
          </MenuPopup>
        </Menu>
      </span>
    </span>
  );
}

/// A tray with a sheet tucked in: the draft put aside.
function StashGlyph() {
  return (
    <svg className="acpmux-stash-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M2.5 9.5v3a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1v-3M2.5 9.5h3l1 1.5h3l1-1.5h3M5 7V3.5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1V7"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
