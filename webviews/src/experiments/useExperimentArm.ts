import { useSyncExternalStore } from "react";
import { experimentArm, type Experiment } from "./experiment";
import { subscribeExperimentSettings } from "./hostSettings";

// One arm per experiment id, read once and kept until a switch or the debug key changes, so a page
// with many menu hosts parses no localStorage per render.
const cached = new Map<string, string>();
let listening = false;

function forget(): void {
  cached.clear();
}

function subscribe(listener: () => void): () => void {
  if (!listening) {
    listening = true;
    subscribeExperimentSettings(forget);
    globalThis.window?.addEventListener?.("storage", forget);
  }
  return subscribeExperimentSettings(listener);
}

function cachedArm<Arm extends string>(experiment: Experiment<Arm>): Arm {
  let arm = cached.get(experiment.id);
  if (arm === undefined) {
    arm = experimentArm(experiment);
    cached.set(experiment.id, arm);
  }
  return arm as Arm;
}

/** `experimentArm(experiment)` that re-renders when a Settings switch (`experiments.*`) changes, with no reload. */
export function useExperimentArm<Arm extends string>(experiment: Experiment<Arm>): Arm {
  const arm = () => cachedArm(experiment);
  return useSyncExternalStore(subscribe, arm, arm);
}
