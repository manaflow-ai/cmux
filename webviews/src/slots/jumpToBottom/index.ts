// The Jump to latest slot with the variants cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import "./jumpToBottom.css";
import { registerSlotVariant } from "../registry";
import { BobArrow } from "./BobArrow";
import { CascadeChevrons } from "./CascadeChevrons";
import { DefaultJumpArrow } from "./DefaultJumpArrow";
import { NudgeArrow } from "./NudgeArrow";
import { jumpToBottomSlot } from "./slot";

export { jumpToBottomSlot, type JumpToBottomProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (registry.test.tsx holds the two equal). */
export const JUMP_TO_BOTTOM_VARIANTS = {
  default: DefaultJumpArrow,
  nudge: NudgeArrow,
  bob: BobArrow,
  cascade: CascadeChevrons,
} as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerJumpToBottomVariants(): void {
  for (const [id, component] of Object.entries(JUMP_TO_BOTTOM_VARIANTS))
    registerSlotVariant(jumpToBottomSlot, id, component);
}

registerJumpToBottomVariants();
