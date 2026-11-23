// The composer's caret as a theme slot (schemas/theme/slots.json `composer.caret`): a mark drawn over
// the prompt field, beside the field's own caret (styles.css `.acpmux-composer-field`, `caret-color:
// var(--cmux-caret, ...)`). ComposerBox.tsx owns the field; the slot draws inside the field's box,
// after the field, and never takes the pointer or focus.
import { defineSlot } from "../registry";

export type ComposerCaretProps = {
  /** The prompt holds no text (only spaces, or nothing). */
  empty: boolean;
};

export const composerCaretSlot = defineSlot<ComposerCaretProps>("composer.caret");
