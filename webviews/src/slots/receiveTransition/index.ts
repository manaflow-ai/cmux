// The receive transition slot with the variant cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import { registerSlotVariant } from "../registry";
import { DefaultReplyArrival } from "./DefaultReplyArrival";
import { receiveTransitionSlot } from "./slot";

export { receiveTransitionSlot, type ReceiveTransitionProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (Slots.defaults.test.tsx holds the two equal). */
export const RECEIVE_TRANSITION_VARIANTS = { default: DefaultReplyArrival } as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerReceiveTransitionVariants(): void {
  for (const [id, component] of Object.entries(RECEIVE_TRANSITION_VARIANTS))
    registerSlotVariant(receiveTransitionSlot, id, component);
}

registerReceiveTransitionVariants();
