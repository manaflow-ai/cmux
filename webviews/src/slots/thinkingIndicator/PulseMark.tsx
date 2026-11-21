// `chat.thinkingIndicator` / `pulse`: one small round mark after the word swells in once as the think
// starts (`--cmux-breath-period`, the settle curve) and then holds still: a mark that keeps breathing is
// the breathing dot (test/no-breathing-dots.test.ts). Transform and opacity only (thinkingIndicator.css).
import { ReservedLabel, type ThinkingIndicatorProps } from "./slot";

export function PulseMark({ label, verbs }: ThinkingIndicatorProps) {
  return (
    <span className="slot-thinking" data-variant="pulse">
      <ReservedLabel label={label} verbs={verbs} />
      <span className="slot-thinking__mark slot-thinking__pulse-box" aria-hidden="true" inert>
        <span className="slot-thinking__pulse" />
      </span>
    </span>
  );
}
