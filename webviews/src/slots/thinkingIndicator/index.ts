// The thinking indicator slot with the variants cmux ships, registered as a theme pack registers its own
// (docs/cmux-next/extensions/replace-a-slot.md). Importing this module is enough to draw the slot.
import "./thinkingIndicator.css";
import { registerSlotVariant } from "../registry";
import { BlockSteps } from "./BlockSteps";
import { CaretMark } from "./CaretMark";
import { CountingDots } from "./CountingDots";
import { DefaultThinkingIndicator } from "./DefaultThinkingIndicator";
import { PulseMark } from "./PulseMark";
import { thinkingIndicatorSlot } from "./slot";

export { thinkingIndicatorSlot, type ThinkingIndicatorProps } from "./slot";

/** cmux's built-in variants, in schemas/theme/slots.json order (check:theme-slots holds the two equal). */
export const THINKING_INDICATOR_VARIANTS = {
  default: DefaultThinkingIndicator,
  "counting-dots": CountingDots,
  pulse: PulseMark,
  caret: CaretMark,
  blocks: BlockSteps,
} as const;

/** Registers the built-in variants (again, after a test reset). */
export function registerThinkingIndicatorVariants(): void {
  for (const [id, component] of Object.entries(THINKING_INDICATOR_VARIANTS))
    registerSlotVariant(thinkingIndicatorSlot, id, component);
}

registerThinkingIndicatorVariants();
