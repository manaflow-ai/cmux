// Settings > Advanced > Experiments: one person-facing switch per taste prototype, default off (composerHatGroups is on),
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
/// A `false` the host sent is kept apart from a missing key (`experimentSwitchOff`), so a switch that is
/// on by default can pick a look when the person turns it off.
export function setExperimentSwitches(value: unknown): void {
  const next: Record<string, boolean> = {};
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const [name, on] of Object.entries(value)) if (typeof on === "boolean") next[name] = on;
  }
  const names = new Set([...Object.keys(current), ...Object.keys(next)]);
  if ([...names].every((name) => current[name] === next[name])) return;
  current = next;
  for (const listener of listeners) listener();
}

/// The switches object as it is now. A change swaps in a new object (never mutates this one), so a
/// caller can cache what it derives from it against its identity (hostSettings.ts's settingArms).
export function experimentSwitches(): ExperimentSwitches {
  return current;
}

/// Whether switch `name` (`glassToolbarGroups` for `experiments.glassToolbarGroups`) is on now.
export function experimentSwitchOn(name: string): boolean {
  return current[name] === true;
}

/// Whether the host sent switch `name` as off (`false`), not merely left it out.
export function experimentSwitchOff(name: string): boolean {
  return current[name] === false;
}

/// Calls `listener` after every change of the switches; returns the unsubscribe. For a module that
/// is not a component (ui/hoverLook.ts sets a root attribute from its switch).
export function subscribeExperimentSwitches(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

const subscribe = subscribeExperimentSwitches;

/// Switch `name` as the host sent it (`true`, `false`, or `undefined` when left out); re-renders when it
/// changes.
export function useExperimentSwitchState(name: string): boolean | undefined {
  const read = () => current[name];
  return useSyncExternalStore(subscribe, read, read);
}

/// Whether switch `name` is on; re-renders when the person flips it. The same read serves the
/// server snapshot, so a row rendered to a string (the transcript's server renders) reads the
/// switches as they are set now instead of throwing.
export function useExperimentSwitch(name: string): boolean {
  const read = () => current[name] === true;
  return useSyncExternalStore(subscribe, read, read);
}
