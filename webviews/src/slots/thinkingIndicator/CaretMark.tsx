// `chat.thinkingIndicator` / `caret`: a thin caret after the word steps ahead a place at a time, a cursor
// typing ahead of the next words: one transform loop in `steps(3)` over `--cmux-spinner-period`
// (thinkingIndicator.css). It never blinks (test/no-breathing-dots.test.ts).
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
