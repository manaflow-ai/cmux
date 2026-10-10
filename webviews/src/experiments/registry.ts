// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item).
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import { diffTreeDisclosure, treeNameFade } from "../agent-session/acpmux/changes/treeMotion.experiment";
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [diffTreeDisclosure, treeNameFade];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
