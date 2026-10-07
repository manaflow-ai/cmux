// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item); test/experiments.test.ts checks the ids, the arms and each default.
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
