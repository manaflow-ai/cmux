/// Settings > Chat > Compact Summary for Short Turns, off by default (`agentPane.display.compactShortTurns`):
/// a turn with little to hide draws flat, its work in a one-line summary ("4s · Ran 2 commands"),
/// instead of folding under "Worked for 4s" (turns.ts `foldsTurn`). Off, every turn folds under its
/// "Worked for", a short one too, and "Worked for 0s" may read. Leo, 2026-11-25: "why isn't there a
/// toggle? there should be one." Its own module so chatDisplay.ts (the setting's reader) and turns.ts
/// (the shaping) share it with no import cycle.
export const COMPACT_SHORT_TURNS_KEY = "agentPane.display.compactShortTurns";

let on = false;

export const compactShortTurnsOn = (): boolean => on;

/// Set by `setChatDisplay` when the setting's value arrives; true when it changed.
export function setCompactShortTurns(value: boolean): boolean {
  if (value === on) return false;
  on = value;
  return true;
}
