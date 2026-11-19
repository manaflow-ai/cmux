// Every registered experiment is valid, and none is decided but still carrying its losing arms: an arm
// whose description records the pick ("Picked: ...") fails here (experiments/experiment.ts
// `validateExperiments`). The framework's rule: the winner ships as the plain code path and the
// experiment, its losing arms and their code are deleted.
import { expect, test } from "bun:test";
import { validateExperiments, type Experiment } from "../src/experiments/experiment";
import { EXPERIMENTS } from "../src/experiments/registry";

test("every registered experiment is valid and undecided", () => {
  expect(validateExperiments(EXPERIMENTS)).toEqual([]);
});

test("an arm that records its pick is reported", () => {
  const decided: Experiment = {
    id: "decided-look",
    title: "Decided",
    description: "Two looks.",
    arms: {
      a: { label: "A", description: "The first look. Picked: it reads better." },
      b: { label: "B", description: "The second look." },
    },
    defaultArm: "a",
  };
  expect(validateExperiments([decided])).toEqual([
    "decided-look#a: the arm says it was picked: ship it as the plain code path and delete the experiment",
  ]);
});
