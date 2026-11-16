/**
 * The check a menu draws on its picked row: a drawn checkmark on a square box, not the text glyph
 * "✓", which the system font draws thin and stretched (Lucas 2026-11-11). Its weight and size
 * follow AppKit's menu checkmark; it inks in `currentColor` and sits in the menu's state column
 * (`.ui-menu-check`, popupSurface.css).
 */
export function MenuCheckGlyph() {
  return (
    <svg className="ui-menu-check-glyph" viewBox="0 0 12 12" aria-hidden="true">
      <path d="M2.4 6.3 4.9 8.7 9.6 3.3" />
    </svg>
  );
}
