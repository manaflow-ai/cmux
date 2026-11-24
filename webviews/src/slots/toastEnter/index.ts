// The toast enter slot with the variant cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import { registerSlotVariant } from "../registry";
import { DefaultToastEnter } from "./DefaultToastEnter";
import { toastEnterSlot } from "./slot";

export { toastEnterSlot, type ToastEnterProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (Slots.defaults.test.tsx holds the two equal). */
export const TOAST_ENTER_VARIANTS = { default: DefaultToastEnter } as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerToastEnterVariants(): void {
  for (const [id, component] of Object.entries(TOAST_ENTER_VARIANTS))
    registerSlotVariant(toastEnterSlot, id, component);
}

registerToastEnterVariants();
