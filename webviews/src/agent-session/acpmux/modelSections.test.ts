import { describe, expect, test } from "bun:test";
import { modelSections } from "./modelSections";

// cx-jqkx: Lawrence saw Default, Opus 4.5, Sonnet 4.5, Haiku 4.5, Opus 4.6, Sonnet 4.6, Opus 4.7 and
// no Opus 5.5: the picker sorted oldest first and the newest models sat below the fold.
const CLAUDE = [
  ["default", "Default"],
  ["claude-opus-4-5", "Opus 4.5"],
  ["claude-sonnet-4-5", "Sonnet 4.5"],
  ["claude-haiku-4-5", "Haiku 4.5"],
  ["claude-opus-4-6", "Opus 4.6"],
  ["claude-sonnet-4-6", "Sonnet 4.6"],
  ["claude-opus-4-7", "Opus 4.7"],
  ["fable", "Fable 5.1"],
  ["claude-fable-5", "Fable 5"],
  ["opus", "Opus 5.5"],
  ["claude-opus-5", "Opus 5"],
  ["sonnet", "Sonnet 5.5"],
  ["claude-sonnet-5", "Sonnet 5"],
  ["haiku", "Haiku 5.5"],
].map(([id, name]) => ({ id: id!, name: name! }));

const names = (models: { name: string }[]) => models.map((model) => model.name);

describe("modelSections", () => {
  test("the default and each family's newest model come first; older versions follow, newest first", () => {
    const { latest, older } = modelSections(CLAUDE, "Claude Code");
    expect(names(latest)).toEqual(["Default", "Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]);
    expect(names(older)).toEqual([
      "Fable 5",
      "Opus 5",
      "Sonnet 5",
      "Opus 4.7",
      "Opus 4.6",
      "Sonnet 4.6",
      "Opus 4.5",
      "Sonnet 4.5",
      "Haiku 4.5",
    ]);
  });

  test("every variant of a family's newest version is latest, and a model with no version is never hidden", () => {
    const { latest, older } = modelSections(
      [
        { id: "claude-opus-5", name: "Opus 5" },
        { id: "opus[1m]", name: "Opus 5.5 · 1M context" },
        { id: "opus", name: "Opus 5.5" },
        { id: "opusplan", name: "Opus plan · Sonnet execute" },
      ],
      "Claude Code",
    );
    expect(names(latest)).toEqual(["Opus 5.5 · 1M context", "Opus 5.5", "Opus plan · Sonnet execute"]);
    expect(names(older)).toEqual(["Opus 5"]);
  });

  test("another harness's families work the same way", () => {
    const { latest, older } = modelSections(
      [
        { id: "gpt-5.4", name: "GPT-5.4" },
        { id: "gpt-5.5", name: "GPT-5.5" },
        { id: "o3", name: "o3" },
      ],
      "Codex",
    );
    expect(names(latest)).toEqual(["GPT-5.5", "o3"]);
    expect(names(older)).toEqual(["GPT-5.4"]);
  });

  test("the catalog's family wins, so separate lines of one generation each keep their newest", () => {
    const { latest, older } = modelSections(
      [
        { id: "gpt-6.1-sol", name: "GPT-6.1 Sol", family: "Sol" },
        { id: "gpt-6-astra", name: "GPT-6 Astra", family: "Astra" },
        { id: "gpt-6-sol", name: "GPT-6 Sol", family: "Sol" },
      ],
      "Codex",
    );
    expect(names(latest)).toEqual(["GPT-6.1 Sol", "GPT-6 Astra"]);
    expect(names(older)).toEqual(["GPT-6 Sol"]);
  });
});
