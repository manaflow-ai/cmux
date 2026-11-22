// `useEffectEvent` for a component wrapped in a plain `React.memo` (VirtualTranscript's TranscriptView).
// React 19.2.3 hands an effect event its new render's function only for a plain function component's
// fiber, never a `React.memo` one's (react-dom's commitBeforeMutationEffects: `case 15: break`), so an
// effect there ran the function from its first render each time: the transcript stopped opening at its
// latest row. The function is handed over in an insertion effect instead, which runs before every
// layout and passive effect of the same commit, so an effect calls the function of the render it
// commits, as `useEffectEvent` does.
import { useCallback, useInsertionEffect, useRef } from "react";

/// A stable function that runs the latest committed render's `run`. Call it from effects only.
export function useCommittedEvent<A extends unknown[], R>(run: (...args: A) => R): (...args: A) => R {
  const latest = useRef(run);
  useInsertionEffect(() => {
    latest.current = run;
  });
  return useCallback((...args: A) => latest.current(...args), []);
}
