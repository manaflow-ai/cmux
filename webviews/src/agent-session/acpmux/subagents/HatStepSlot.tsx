// The composer hat's step slot (hatStep.experiment.ts): what a running subagent does now, in a slot
// whose width never changes, at most one change per dwell (hatStep.ts).
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { HAT_PHASES, hatPhaseWord, PHASE_DWELL_MS, SAMPLE_DWELL_MS, type HatPhase } from "./hatStep";

/// `value`, changing at most once per `dwellMs`: a change inside the dwell waits for its end, and
/// only the newest waiting value then shows, so a burst collapses to one change.
export function useDwell<T>(value: T, dwellMs: number): T {
  const [shown, setShown] = useState(value);
  // The first value is held too: a part that mounts mid-burst (a new kind in the hat's header) shows
  // what it mounted with for a whole dwell before its first change.
  const [mountedAt] = useState(Date.now);
  const shownAt = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (Object.is(value, shown)) return;
    const wait = (shownAt.current ?? mountedAt) + dwellMs - Date.now();
    const show = () => {
      shownAt.current = Date.now();
      setShown(value);
    };
    if (wait <= 0) {
      show();
      return;
    }
    const timer = setTimeout(show, wait);
    return () => clearTimeout(timer);
  }, [value, shown, dwellMs, mountedAt]);
  return shown;
}

/// Draws `children(value)` with `value` held as `useDwell` holds it: for a part that renders after an
/// early return, where the hook itself can't go (the hat's header words and count, SubagentTray.tsx).
export function Dwelt<T>({
  value,
  dwellMs,
  children,
}: {
  value: T;
  dwellMs: number;
  children: (shown: T) => ReactNode;
}) {
  return <>{children(useDwell(value, dwellMs))}</>;
}

/// One word from a fixed list, stacked over every other word of the list (hidden), so the slot is
/// always the widest word's width; a new word cross-fades in place.
export function HatPhaseSlot({ phase, className }: { phase: HatPhase; className?: string }) {
  const t = useT();
  const shown = useDwell(phase, PHASE_DWELL_MS);
  return (
    <span className={`acpmux-hat-step acpmux-hat-step--phase${className ? ` ${className}` : ""}`} data-phase={shown}>
      {HAT_PHASES.map((each) => (
        <span
          key={each}
          className="acpmux-hat-step__word"
          data-on={each === shown ? "" : undefined}
          aria-hidden={each !== shown}
        >
          {hatPhaseWord(t, each)}
        </span>
      ))}
    </span>
  );
}

/// The exact call, at most one change per SAMPLE_DWELL_MS, in a slot of fixed width that cuts it.
export function HatSampledSlot({ text, className }: { text: string; className?: string }) {
  const shown = useDwell(text, SAMPLE_DWELL_MS);
  return (
    <span className={`acpmux-hat-step acpmux-hat-step--sampled${className ? ` ${className}` : ""}`} title={shown}>
      <span key={shown} className="acpmux-hat-step__word" data-on="">
        {shown}
      </span>
    </span>
  );
}
