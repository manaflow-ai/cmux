// The agent chat's thinking indicator as a theme slot (schemas/theme/slots.json `chat.thinkingIndicator`):
// the live line's word while a turn thinks before it names a step, and how it shows the agent working.
// Thinking.tsx draws it inside the line's `<output>`; the clock, tokens and counts after it stay the line's.
import type { ReactNode } from "react";
import { useMemo } from "react";
import { defineSlot } from "../registry";

export type ThinkingIndicatorProps = {
  /** "Thinking", the turn's rotating verb or a custom verb, already translated. */
  label: string;
  /** Every label the line may rotate through: the word reserves the widest. */
  verbs: readonly string[];
  /** The time drawn after the slot ("12s"), when the line shows one. */
  elapsed?: string;
  /** How long the turn has run, from the line's existing one-second clock (never a timer of the slot's). */
  elapsedMs: number;
};

export const thinkingIndicatorSlot = defineSlot<ThinkingIndicatorProps>("chat.thinkingIndicator");

/** The inert sizing samples that reserve the widest verb (conversation.css `.cv-status-verb__size`):
 * never in copy, Find or the live region. */
export function useVerbSizes(verbs: readonly string[]): ReactNode[] {
  return useMemo(
    () =>
      verbs.map((word, index) => (
        <span key={index} className="cv-status-verb__size" data-text={word} aria-hidden="true" inert />
      )),
    [verbs],
  );
}

/** The word at its reserved width, in the line's tone: what every variant but the default draws first. */
export function ReservedLabel({ label, verbs }: Pick<ThinkingIndicatorProps, "label" | "verbs">) {
  const sizes = useVerbSizes(verbs);
  return (
    <span className="cv-shimmer__base">
      <span className="cv-status-verb">
        {sizes}
        <span className="cv-status-verb__word">{label}</span>
      </span>
    </span>
  );
}
