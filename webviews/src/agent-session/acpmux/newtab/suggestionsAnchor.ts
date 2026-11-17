import { UI_ANCHOR_GAP } from "../../../ui/anchor";
import type { UiVirtualAnchor } from "../../../ui/Popover";

export function suggestionsAnchor(composer: HTMLElement, box: HTMLElement): UiVirtualAnchor {
  return {
    contextElement: composer,
    getBoundingClientRect() {
      const bounds = composer.getBoundingClientRect();
      const labels = composer.querySelectorAll(
        ".nt-foot .acpmux-mode-text, .nt-foot .acpmux-model-name, .nt-foot .acpmux-model-short",
      );
      for (const label of labels) {
        const text = label.getBoundingClientRect();
        // A collapsed form keeps its box under `visibility: hidden`: only the label drawn counts.
        if (text.height === 0 || getComputedStyle(label).visibility !== "visible") continue;
        // Mirror the box edge across the chip text, then cancel the shared popover gap.
        // Keep the top edge so an upward popover still clears the whole composer.
        const bottom = text.bottom + text.top - box.getBoundingClientRect().bottom - UI_ANCHOR_GAP;
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
      }
      return bounds;
    },
  };
}
