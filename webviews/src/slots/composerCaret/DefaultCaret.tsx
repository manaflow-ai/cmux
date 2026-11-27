// `composer.caret` / `default`: the field's own caret, as before slots. It draws no element: the caret
// is the field's, colored by `--cmux-caret` (styles.css `.acpmux-composer-field`).
import type { ComposerCaretProps } from "./slot";

export function DefaultCaret(_props: ComposerCaretProps) {
  return null;
}
