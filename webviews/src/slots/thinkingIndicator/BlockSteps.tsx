// `chat.thinkingIndicator` / `blocks`: three square cells after the word and a lit block stepping across
// them a cell at a time, with no easing, for a retro look: one transform loop in `steps(3)` over
// `--cmux-spinner-period` (thinkingIndicator.css).
import { ReservedLabel, type ThinkingIndicatorProps } from "./slot";

const CELLS = [0, 1, 2] as const;

export function BlockSteps({ label, verbs }: ThinkingIndicatorProps) {
  return (
    <span className="slot-thinking" data-variant="blocks">
      <ReservedLabel label={label} verbs={verbs} />
      <span className="slot-thinking__mark slot-thinking__blocks" aria-hidden="true" inert>
        {CELLS.map((cell) => (
          <span key={cell} className="slot-thinking__cell" />
        ))}
        <span className="slot-thinking__lit-block" />
      </span>
    </span>
  );
}
