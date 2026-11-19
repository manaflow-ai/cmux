import { useSyncExternalStore } from "react";
import { experimentArm, type Experiment } from "./experiment";
import { subscribeExperimentSettings } from "./hostSettings";

/** `experimentArm(experiment)` that re-renders when a Settings switch (`experiments.*`) changes, with no reload. */
export function useExperimentArm<Arm extends string>(experiment: Experiment<Arm>): Arm {
  const arm = () => experimentArm(experiment);
  return useSyncExternalStore(subscribeExperimentSettings, arm, arm);
}
