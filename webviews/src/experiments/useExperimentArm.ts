import { useSyncExternalStore } from "react";
import { EXPERIMENTS_STORAGE_KEY, experimentArm, type Experiment } from "./experiment";
import { subscribeExperimentSettings } from "./hostSettings";

// One arm per experiment id, kept while its sources are the same objects and the same stored text, so a
// page with many menu hosts parses no localStorage per render; any change of a source reads them again.
const cached = new Map<string, string>();
let sources: [unknown, unknown, string | null | undefined] | undefined;

function storedText(): string | null | undefined {
  try {
    return globalThis.localStorage?.getItem(EXPERIMENTS_STORAGE_KEY);
  } catch {
    return undefined;
  }
}

function cachedArm<Arm extends string>(experiment: Experiment<Arm>): Arm {
  const now: [unknown, unknown, string | null | undefined] = [
    globalThis.cmuxExperiments,
    globalThis.cmuxExperimentSettings,
    storedText(),
  ];
  if (!sources || sources.some((value, index) => value !== now[index])) {
    cached.clear();
    sources = now;
  }
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
  return useSyncExternalStore(subscribeExperimentSettings, arm, arm);
}
