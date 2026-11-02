import { expect, test } from "bun:test";
import { agentDisplayName, modelChipFallback } from "./agents";

test("the Chief harness is named Chief", () => {
  expect(agentDisplayName("chief")).toBe("Chief");
});

test("a harness that offers no models names itself on the model chip, not 'Model'", () => {
  // The Chief picks its own engine: its chat has no model list, so the chip says whose chat it is.
  expect(modelChipFallback({ id: "chief", name: "Chief", models: [] }, [])).toBe("Chief");
  expect(modelChipFallback({ id: "chief", models: [] }, [])).toBe("Chief");
  // A harness with models (in its catalog row or from its session) keeps the generic label.
  expect(modelChipFallback({ id: "claude", name: "Claude Code", models: [{ id: "opus" }] }, [])).toBeUndefined();
  expect(modelChipFallback({ id: "codex", models: [] }, [{ id: "gpt" }])).toBeUndefined();
  expect(modelChipFallback(undefined, [])).toBeUndefined();
});

test("acpmux's placeholder default model is no model", () => {
  // acpmux lists a harness that reports none with `default (agent's choice)` only.
  const only = [{ id: "default", name: "default (agent's choice)" }];
  expect(modelChipFallback({ id: "chief", name: "Chief", models: only }, only)).toBe("Chief");
});
