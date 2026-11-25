// The compound-motion cases (compoundScenarios.tsx plays them) and the step each one's event starts
// in, with no imports: the motion map's test reads them outside a page.
export const COMPOUND_CASES = [
  "control",
  "send-1",
  "send-5",
  "send-15",
  "send-5-one-commit",
  "queue-scrolled",
  "steer",
  "fold-stream",
  "resize-fold",
  "growth-stream",
  "stack-stream",
  "subagent-land",
  "recap-end",
] as const;
export type CompoundCase = (typeof COMPOUND_CASES)[number];

/// The step each case's event starts in (the map's window starts there).
export const EVENT_STEP: Record<CompoundCase, string> = {
  control: "rest",
  "send-1": "send",
  "send-5": "send",
  "send-15": "send",
  "send-5-one-commit": "send",
  "queue-scrolled": "send",
  steer: "steer",
  "fold-stream": "open",
  "resize-fold": "open",
  "growth-stream": "grow",
  "stack-stream": "queue",
  "subagent-land": "land",
  "recap-end": "end",
};
