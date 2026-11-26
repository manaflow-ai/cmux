import { EXPERIMENTS_STORAGE_KEY, experimentArm, type Experiment } from "./experiment";
import { switchFor } from "./hostSettings";
import { useExperimentSwitchState } from "./switches";

// One arm per experiment id, kept while its sources are the same (the host override object, the stored
// debug text and its switch), so a page with many menu hosts parses no localStorage per render; any
// change of a source reads them again.
const cached = new Map<
  string,
  { overrides: unknown; stored: string | null | undefined; on: boolean | undefined; arm: string }
>();

function storedText(): string | null | undefined {
  try {
    return globalThis.localStorage?.getItem(EXPERIMENTS_STORAGE_KEY);
  } catch {
    return undefined;
  }
}

/**
 * `experimentArm(experiment)` that re-renders when its Settings switch (`experiments.*`) flips, with no
 * reload. It subscribes only to its own switch, so a menu host re-renders on no other change.
 */
export function useExperimentArm<Arm extends string>(experiment: Experiment<Arm>): Arm {
  const on = useExperimentSwitchState(switchFor(experiment.id) ?? "");
  const overrides = globalThis.cmuxExperiments;
  const stored = storedText();
  const hit = cached.get(experiment.id);
  if (hit && hit.overrides === overrides && hit.stored === stored && hit.on === on) return hit.arm as Arm;
  const arm = experimentArm(experiment);
  cached.set(experiment.id, { overrides, stored, on, arm });
  return arm;
}
