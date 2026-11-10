// `chat.thinkingIndicator` / `caret`: a thin caret after the word blinks on and off, a cursor waiting for
// the next words: opacity in two hard steps over half a `--cmux-spinner-period` (thinkingIndicator.css).
import { ReservedLabel, type ThinkingIndicatorProps } from "./slot";

export function CaretMark({ label, verbs }: ThinkingIndicatorProps) {
  return (
    <span className="slot-thinking" data-variant="caret">
      <ReservedLabel label={label} verbs={verbs} />
      <span className="slot-thinking__mark slot-thinking__caret-box" aria-hidden="true" inert>
        <span className="slot-thinking__caret" />
      </span>
    </span>
  );
}
