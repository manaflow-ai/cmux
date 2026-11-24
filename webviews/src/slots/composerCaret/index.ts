// The composer caret slot with the variant cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import { registerSlotVariant } from "../registry";
import { DefaultCaret } from "./DefaultCaret";
import { composerCaretSlot } from "./slot";

export { composerCaretSlot, type ComposerCaretProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (Slots.defaults.test.tsx holds the two equal). */
export const COMPOSER_CARET_VARIANTS = { default: DefaultCaret } as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerComposerCaretVariants(): void {
  for (const [id, component] of Object.entries(COMPOSER_CARET_VARIANTS))
    registerSlotVariant(composerCaretSlot, id, component);
}

registerComposerCaretVariants();
