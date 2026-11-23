// Settings > Advanced > Experiments: one person-facing switch per taste prototype, each default off,
// under the cmux.json `experiments` object (schemas/settings/source/experiments.json). The App pushes
// the whole object to every agent page (`cmuxAcpmuxBridge.applyExperiments`, Swift
// AgentPanePageSettings); a component reads its own switch with `useExperimentSwitch(name)`. Kept
// here, not in App state, so a push that arrives before a component mounts is kept. A gallery stage
// sets switches with `setExperimentSwitches` before it renders.
//
// Not the same thing as experiment.ts's arms: an arm picks between looks for comparison in the
// gallery; a switch is whether the person turned the prototype on at all.
import { useSyncExternalStore } from "react";

export type ExperimentSwitches = Readonly<Record<string, boolean>>;

let current: ExperimentSwitches = {};
const listeners = new Set<() => void>();

/// The host's `experiments` object: each `true` value is on, anything else (or a missing key) is off.
export function setExperimentSwitches(value: unknown): void {
  const next: Record<string, boolean> = {};
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const [name, on] of Object.entries(value)) if (on === true) next[name] = true;
  }
  const names = new Set([...Object.keys(current), ...Object.keys(next)]);
  if ([...names].every((name) => current[name] === next[name])) return;
  current = next;
  for (const listener of listeners) listener();
}

/// Whether switch `name` (`glassToolbarGroups` for `experiments.glassToolbarGroups`) is on now.
export function experimentSwitchOn(name: string): boolean {
  return current[name] === true;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// Whether switch `name` is on; re-renders when the person flips it.
/// A server render (the transcript's row renders, tests) reads the same value: without that snapshot
/// React throws, and a component under every tool call (ToolWidget) took the row down with it.
export function useExperimentSwitch(name: string): boolean {
  const on = () => current[name] === true;
  return useSyncExternalStore(subscribe, on, on);
}
