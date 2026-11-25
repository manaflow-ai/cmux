// The /side slot with the variant cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import { registerSlotVariant } from "../registry";
import { DefaultSideNote } from "./DefaultSideNote";
import { sideSlot } from "./slot";

export { sideSlot, type SideProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (Slots.defaults.test.tsx holds the two equal). */
export const SIDE_VARIANTS = { default: DefaultSideNote } as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerSideVariants(): void {
  for (const [id, component] of Object.entries(SIDE_VARIANTS)) registerSlotVariant(sideSlot, id, component);
}

registerSideVariants();
