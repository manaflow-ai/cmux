// The composer outcome hints' on-demand arms (composerOutcomeHints.experiment.ts; Leo 2026-11-22
// 09:50Z: "this is good as tips"): whether the / and @ lists show keyboard action hints,
// and which placeholder the empty composer shows, for the arm in force.
import { useSyncExternalStore } from "react";
import { experimentArm } from "../../experiments/experiment";
import { composerOutcomeHints } from "./composerOutcomeHints.experiment";
import { useOptionHeld } from "./useOptionHeld";

export type OutcomePlaceholder = "agent" | "modes" | undefined;

export interface OutcomeHints {
  /** Keyboard action hints on the highlighted / or @ row. */
  rows: boolean;
  /** The placeholder naming the agent ("agent") or the agent and both lists ("modes"). */
  placeholder: OutcomePlaceholder;
}

// The `hint` arm's "?": shown or not, for this page only (it never persists, so a reload is minimal
// again). One value for the page, since the composer and its lists read it apart.
let revealed = false;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
export function setHintsRevealed(next: boolean): void {
  if (next === revealed) return;
  revealed = next;
  for (const listener of listeners) listener();
}
export const hintsRevealed = (): boolean => revealed;
export function useHintsRevealed(): boolean {
  return useSyncExternalStore(subscribe, hintsRevealed, hintsRevealed);
}

/** What the arm in force shows now: `now` nothing, `agent`/`modes` a placeholder, `outcomes`
 *  everything always, `hint` everything while its "?" is on, `option` everything while Option is
 *  held, `tip` nothing (its tip says it, featureTips.tsx). */
export function outcomeHintsFor(arm: string, onDemand: boolean): OutcomeHints {
  if (arm === "agent") return { rows: false, placeholder: "agent" };
  if (arm === "modes") return { rows: false, placeholder: "modes" };
  if (arm === "outcomes") return { rows: true, placeholder: "modes" };
  if ((arm === "hint" || arm === "option") && onDemand) return { rows: true, placeholder: "modes" };
  return { rows: false, placeholder: undefined };
}

export function useOutcomeHints(): OutcomeHints {
  const arm = experimentArm(composerOutcomeHints);
  const held = useOptionHeld(arm === "option");
  const shown = useHintsRevealed();
  return outcomeHintsFor(arm, arm === "option" ? held : arm === "hint" && shown);
}
