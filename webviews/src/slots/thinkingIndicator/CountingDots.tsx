// `chat.thinkingIndicator` / `counting-dots`: three dim dots after the word and a lit dot stepping from
// one to the next; once the turn has thought for LONG_THINK_MS a fourth dot grows in and the lit dot
// counts four, so a long think reads as longer. CSS only (thinkingIndicator.css): one transform loop in
// `steps()` on `--cmux-spinner-period`, never a fade (no dot breathes: test/no-breathing-dots.test.ts),
// and one transform as the fourth dot arrives. The count comes from `elapsedMs`, which the line's
// existing one-second clock updates; this component starts no timer.
import { ReservedLabel, type ThinkingIndicatorProps } from "./slot";

/** How long a turn thinks before the fourth dot joins. */
export const LONG_THINK_MS = 20_000;

const DOTS = [0, 1, 2, 3] as const;

export function CountingDots({ label, verbs, elapsedMs }: ThinkingIndicatorProps) {
  const long = elapsedMs >= LONG_THINK_MS;
  return (
    <span className="slot-thinking" data-variant="counting-dots">
      <ReservedLabel label={label} verbs={verbs} />
      <span
        className="slot-thinking__mark slot-thinking__dots"
        data-long={long ? "" : undefined}
        aria-hidden="true"
        inert
      >
        {DOTS.map((dot) => (
          <span key={dot} className="slot-thinking__dot" data-dot={dot} />
        ))}
        <span className="slot-thinking__lit-dot" />
      </span>
    </span>
  );
}
