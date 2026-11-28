/// Test probes: how many times the group built its step list and each step drew, and `hold`, which
/// takes each deferred draw of an opened run's rows (StepList) to run when the test says. Unset in
/// the app.
export const stepProbe: {
  build?: () => void;
  render?: (key: string) => void;
  hold?: (draw: () => void) => void;
} = {};

/// The least height a step row draws at, in px: the rows the window can show at once are its height
/// over this.
const STEP_MIN_PX = 24;

/// Steps a reader's click draws in its own frame: as many as the window can show, never the whole of
/// a long run. Its height alone sets the count, so the click costs the same at any length.
export function firstStepCount(viewHeight: number): number {
  return Math.max(1, Math.ceil(viewHeight / STEP_MIN_PX));
}
