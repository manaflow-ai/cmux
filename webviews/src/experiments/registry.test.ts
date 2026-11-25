import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { defineExperiment } from "./experiment";
import { EXPERIMENTS, experimentById, experimentsIn } from "./registry";

const SRC = `${import.meta.dir}/..`;

/** `export const NAME = defineExperiment(` in each experiment file, read as text (no loader involved). */
function declaredExperiments(): { file: string; name: string }[] {
  const declared: { file: string; name: string }[] = [];
  for (const file of new Bun.Glob("**/*.experiment.{ts,tsx}").scanSync({ cwd: SRC })) {
    const text = readFileSync(`${SRC}/${file}`, "utf8");
    for (const match of text.matchAll(/^export const (\w+)\s*=\s*defineExperiment\b/gm)) {
      declared.push({ file, name: match[1] });
    }
  }
  return declared;
}

describe("experiment registry", () => {
  test("registers every experiment an experiment file exports, and nothing else", () => {
    const declared = declaredExperiments();
    const registered = new Set(EXPERIMENTS);
    for (const { file, name } of declared) {
      const module = import.meta.require(`${SRC}/${file}`) as Record<string, unknown>;
      expect(registered.has(module[name] as never)).toBe(true);
    }
    expect(EXPERIMENTS.length).toBe(declared.length);
  });

  test("finds an experiment by id", () => {
    for (const experiment of EXPERIMENTS) expect(experimentById(experiment.id)).toBe(experiment);
    expect(experimentById("no-such-experiment")).toBeUndefined();
  });

  test("takes only experiments from a module, in path then export order", () => {
    const arms = { a: { label: "A", description: "a" }, b: { label: "B", description: "b" } };
    const first = defineExperiment({ id: "first", title: "", description: "", arms, defaultArm: "a" });
    const second = defineExperiment({ id: "second", title: "", description: "", arms, defaultArm: "b" });
    const third = defineExperiment({ id: "third", title: "", description: "", arms, defaultArm: "a" });
    const found = experimentsIn({
      "../z/two.experiment.ts": { third, SWITCH: "switchName" },
      "../a/one.experiment.ts": { first, helper: () => 1, second, nothing: undefined },
    });
    expect(found).toEqual([first, second, third]);
  });
});
