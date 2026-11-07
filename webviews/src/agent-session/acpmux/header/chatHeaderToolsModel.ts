import { type MouseEvent, type PointerEvent } from "react";

/// Every header button's glyph (header.css): Claude Code desktop's top strip draws one size for all of
/// them, the Needs you inbox and Session Info toggle included.
export const HEADER_GLYPH = 16;

export { HEADER_ACTIONS } from "./headerActions";

export type ChatMenuItem =
  | "separator"
  | {
      key: string;
      label: string;
      icon: string;
      /// A picture drawn in the icon's place (the chat's own avatar on Set Chat Avatar…, avatarRow.ts);
      /// `icon` stays for a surface that draws only glyphs (the native menu, the palette).
      image?: string;
      /// An app action id whose keycap the row shows.
      shortcutAction?: string;
      /// A letter that picks the row while the menu is open (Rename R, Fork F). It is never drawn: a
      /// bare letter on the row's right reads as meaningless (design/menus.md, Leo 2026-10-31).
      accelerator?: string;
      disabled?: boolean;
      onSelect?: (event?: MouseEvent<HTMLElement> | PointerEvent<HTMLElement>) => void;
      children?: ChatMenuChild[];
    };

/// The menu's groups in order, the empty ones dropped, with a separator between each two.
export const menuGroups = (...groups: ChatMenuItem[][]): ChatMenuItem[] =>
  groups.filter((group) => group.length > 0).flatMap((group, index) => (index ? ["separator", ...group] : group));

/// A submenu row: its label, and the keycap of `shortcutAction` when it has one. A row with `checked`
/// is one of a choice (the rows next to it with `checked` too), drawn with a check on the picked one;
/// `separatorBefore` draws a line above the row.
export type ChatMenuChild = {
  key: string;
  label: string;
  disabled?: boolean;
  shortcutAction?: string;
  accelerator?: string;
  checked?: boolean;
  /// A row that is on or off on its own (Transcript view's Wrap lines), drawn with a check when on.
  on?: boolean;
  separatorBefore?: boolean;
  onSelect: () => void;
};

/// Modifier glyphs a drawn menu keycap must carry, as in ⌘N or ⇧⌘I.
const MODIFIER_GLYPHS = /[⌘⌥⌃⇧]/;

/// The keycap a menu row may draw: a real shortcut with a modifier, never a bare letter (a bare
/// letter only works while the menu is open, so it reads as meaningless on the row's right).
export function menuKeycap(shortcut: string | undefined): string | undefined {
  return shortcut && MODIFIER_GLYPHS.test(shortcut) ? shortcut : undefined;
}

type ShortcutMenuItem = Exclude<ChatMenuItem, "separator"> | ChatMenuChild;

export function menuItemForShortcut(
  items: readonly (ChatMenuItem | ChatMenuChild)[],
  key: string,
): ShortcutMenuItem | undefined {
  const normalized = key.length === 1 ? key.toUpperCase() : "";
  if (!normalized) return undefined;
  return items.find(
    (item): item is ShortcutMenuItem => item !== "separator" && item.accelerator?.toUpperCase() === normalized,
  );
}

/** A popup may outlive the selected chat until React commits the new view. Its callbacks must
 * remain bound to the chat that opened it, including submenu callbacks. */
export function guardedChatMenu(items: ChatMenuItem[], current: () => boolean): ChatMenuItem[] {
  // The selection event goes through: Fork's Option-click opens its destination chooser (forkMenu.ts).
  const guard =
    <E>(run: (event?: E) => void) =>
    (event?: E) => {
      if (current()) run(event);
    };
  return items.map((item) =>
    item === "separator"
      ? item
      : {
          ...item,
          ...(item.onSelect && { onSelect: guard(item.onSelect) }),
          ...(item.children && {
            children: item.children.map((child) => ({ ...child, onSelect: guard(child.onSelect) })),
          }),
        },
  );
}
