// The send transition slot with the variant cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import { registerSlotVariant } from "../registry";
import { DefaultSendBubble } from "./DefaultSendBubble";
import { sendTransitionSlot } from "./slot";

export { sendTransitionSlot, type SendTransitionProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (Slots.defaults.test.tsx holds the two equal). */
export const SEND_TRANSITION_VARIANTS = { default: DefaultSendBubble } as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerSendTransitionVariants(): void {
  for (const [id, component] of Object.entries(SEND_TRANSITION_VARIANTS))
    registerSlotVariant(sendTransitionSlot, id, component);
}

registerSendTransitionVariants();
