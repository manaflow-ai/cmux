// The row hover slot with the variant cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import { registerSlotVariant } from "../registry";
import { DefaultReplyActionsRow } from "./DefaultReplyActionsRow";
import { rowHoverSlot } from "./slot";

export { rowHoverSlot, type RowHoverProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (Slots.defaults.test.tsx holds the two equal). */
export const ROW_HOVER_VARIANTS = { default: DefaultReplyActionsRow } as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerRowHoverVariants(): void {
  for (const [id, component] of Object.entries(ROW_HOVER_VARIANTS)) registerSlotVariant(rowHoverSlot, id, component);
}

registerRowHoverVariants();
