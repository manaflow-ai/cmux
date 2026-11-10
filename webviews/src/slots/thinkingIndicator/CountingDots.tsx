// `chat.thinkingIndicator` / `counting-dots`: three dots after the word light one after another with a
// rest beat; once the turn has thought for LONG_THINK_MS a fourth dot grows into the rest beat, so a
// long think reads as longer. CSS only (thinkingIndicator.css): opacity beats on `--cmux-spinner-period`
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
      <span className="slot-thinking__mark slot-thinking__dots" data-long={long ? "" : undefined} aria-hidden="true" inert>
        {DOTS.map((dot) => (
          <span key={dot} className="slot-thinking__dot" data-dot={dot} />
        ))}
      </span>
    </span>
  );
}
