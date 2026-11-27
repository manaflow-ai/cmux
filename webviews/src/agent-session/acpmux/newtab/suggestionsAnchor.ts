import { UI_ANCHOR_GAP } from "../../../ui/anchor";
import type { UiVirtualAnchor } from "../../../ui/Popover";

/// The suggestions open 8 px under the card (the quiet row draws inside it, screen.css), at the composer's zoom
/// (`--cmux-composer-zoom`, density and the person's text size), so the gap reads the same at every size. The top edge
/// stays the composer's, so an upward popover still clears the whole composer.
export const SUGGESTIONS_GAP = 8;

export function suggestionsAnchor(composer: HTMLElement, box: HTMLElement): UiVirtualAnchor {
  return {
    contextElement: composer,
    getBoundingClientRect() {
      const bounds = composer.getBoundingClientRect();
      const zoom = Number.parseFloat(getComputedStyle(composer).getPropertyValue("--cmux-composer-zoom")) || 1;
      // Cancel the shared popover gap, which the overlay adds under the anchor.
      const bottom = box.getBoundingClientRect().bottom + SUGGESTIONS_GAP * zoom - UI_ANCHOR_GAP;
      return {
        x: bounds.x,
        y: bounds.y,
        left: bounds.left,
        right: bounds.right,
        top: bounds.top,
        bottom,
        width: bounds.width,
        height: bottom - bounds.top,
        toJSON: () => ({ ...bounds.toJSON(), bottom, height: bottom - bounds.top }),
      };
    },
  };
}
