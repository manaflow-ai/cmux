import { describe, expect, test } from "bun:test";
import {
  buildTaxonomy,
  classify,
  defaultModel,
  effortFor,
  filterModels,
  fold,
  landOnFamily,
  landOnProvider,
  providerDefault,
  rankFamilies,
  rankModels,
  runnableRecents,
  versionOf,
} from "./modelTaxonomy";
import { modelPickerVariant } from "./modelPickerVariant";
import { aimingAt, insideTriangle } from "./useHoverIntent";
import { claudeModels, codexModels } from "./mockFixture";

const claude = buildTaxonomy(claudeModels, "Claude Code");
const codex = buildTaxonomy(codexModels, "Codex");
const family = (taxonomy: typeof claude, name: string) =>
  taxonomy.providers.flatMap((provider) => provider.families).find((candidate) => candidate.name === name)!;
const names = (models: { name: string }[]) => models.map((model) => model.name);

describe("model taxonomy", () => {
  test("classifies providers and families from ids and names, unknown ones under the harness", () => {
    expect(classify({ id: "claude-opus-5-5", name: "Opus 5.5" }, "Claude Code")).toEqual({
      provider: "Anthropic",
      family: "Opus",
    });
    expect(classify({ id: "claude-3-5-sonnet-20241022" }, "Claude Code")).toEqual({
      provider: "Anthropic",
      family: "Sonnet",
    });
    expect(classify({ id: "claude-fable-1", name: "Fable 1" }, "x").family).toBe("Fable");
    expect(classify({ id: "sonnet", name: "Claude Sonnet" }, "x")).toEqual({ provider: "Anthropic", family: "Sonnet" });
    expect(classify({ id: "gpt-6-astra", name: "GPT-6-Astra" }, "Codex")).toEqual({
      provider: "OpenAI",
      family: "GPT-6",
    });
    expect(classify({ id: "gpt-5.5-codex" }, "Codex").family).toBe("GPT-5");
    expect(classify({ id: "o4-mini" }, "Codex")).toEqual({ provider: "OpenAI", family: "o4" });
    expect(classify({ id: "gpt-oss-120b" }, "Codex")).toEqual({ provider: "OpenAI", family: "gpt-oss" });
    expect(classify({ id: "qwen3-coder", name: "Qwen3 Coder" }, "Codex").provider).toBe("Qwen");
    expect(classify({ id: "gemini-3-pro" }, "Gemini CLI")).toEqual({ provider: "Google", family: "Gemini 3" });
    expect(classify({ id: "zeta-large", name: "Zeta Large" }, "Amp")).toEqual({ provider: "Amp", family: "Zeta" });
  });

  test("groups the catalog into providers and families, each family newest first", () => {
    expect(claude.providers.map((provider) => provider.name)).toEqual(["Anthropic"]);
    expect(claude.providers[0]!.families.map((entry) => entry.name)).toEqual(["Opus", "Sonnet", "Haiku", "Fable"]);
    expect(names(family(claude, "Opus").models)).toEqual(["Opus 5.5", "Opus 5", "Opus 4.6", "Opus 4.1"]);
    expect(codex.providers.map((provider) => provider.name)).toEqual(["OpenAI", "Qwen", "Mistral"]);
    expect(codex.providers[0]!.families.map((entry) => entry.name)).toEqual(["GPT-6", "GPT-5", "o4", "o3", "gpt-oss"]);
    expect(versionOf({ id: "claude-opus-4-1", name: "Opus 4.1" })).toEqual([4, 1]);
    expect(versionOf({ id: "claude-opus-4-1" })).toEqual([4, 1]);
  });

  test("a family or provider defaults to the current or last-used model, else its newest", () => {
    const opus = family(claude, "Opus");
    expect(defaultModel(opus.models, [])!.name).toBe("Opus 5.5");
    const recents = [
      { harness: "claude", model: "claude-sonnet-5", effort: "low" },
      { harness: "claude", model: "claude-opus-4-6", effort: "high" },
    ];
    expect(defaultModel(opus.models, recents)!.name).toBe("Opus 4.6");
    expect(defaultModel(opus.models, recents, { model: "claude-opus-5" })!.name).toBe("Opus 5");
    const openai = codex.providers[0]!;
    expect(providerDefault(openai, [])!.name).toBe("GPT-6-Astra");
    expect(providerDefault(openai, [{ harness: "codex", model: "o3" }])!.name).toBe("o3");
    expect(providerDefault(codex.providers[1]!, [])!.name).toBe("Qwen3 Coder");
  });

  test("landing on a family or provider takes its default with that model's recent effort", () => {
    const recents = [
      { harness: "claude", model: "claude-sonnet-5", effort: "low" },
      { harness: "claude", model: "claude-opus-4-6", effort: "high" },
    ];
    const current = { model: "claude-haiku-4-5", effort: "medium" };
    expect(landOnFamily(family(claude, "Sonnet"), recents, current)).toEqual({
      model: "claude-sonnet-5",
      effort: "low",
    });
    // No recent effort for the model: the session's current effort carries over.
    expect(landOnFamily(family(claude, "Fable"), recents, current)).toEqual({
      model: "claude-fable-1-5",
      effort: "medium",
    });
    expect(landOnProvider(codex.providers[0]!, [{ harness: "codex", model: "o3", effort: "high" }], {})).toEqual({
      model: "o3",
      effort: "high",
    });
    expect(effortFor("claude-haiku-4-5", recents, current)).toBe("medium");
  });

  test("levels rank best first, fold the rest, and filter by every typed word", () => {
    const recents = [
      { harness: "claude", model: "claude-opus-4-1" },
      { harness: "claude", model: "claude-sonnet-5" },
    ];
    expect(names(rankModels(family(claude, "Opus").models, recents, { model: "claude-opus-5" }))).toEqual([
      "Opus 5",
      "Opus 4.1",
      "Opus 5.5",
      "Opus 4.6",
    ]);
    expect(rankFamilies(claude.providers[0]!.families, recents).map((entry) => entry.name)).toEqual([
      "Opus",
      "Sonnet",
      "Haiku",
      "Fable",
    ]);
    expect(fold([1, 2, 3, 4, 5], 3, false)).toEqual({ visible: [1, 2, 3], hidden: 2 });
    expect(fold([1, 2, 3, 4], 3, false)).toEqual({ visible: [1, 2, 3, 4], hidden: 0 });
    expect(fold([1, 2, 3, 4, 5], 3, true).hidden).toBe(0);
    expect(names(filterModels(claude, "son"))).toEqual(["Sonnet 5.5", "Sonnet 5", "Sonnet 4.6"]);
    expect(names(filterModels(claude, "opus 4"))).toEqual(["Opus 4.6", "Opus 4.1"]);
    expect(filterModels(claude, "gpt")).toEqual([]);
  });

  test("recents keep only what this harness's catalog runs", () => {
    const recents = [
      { harness: "codex", model: "gpt-6-astra" },
      { harness: "claude", model: "claude-retired" },
      { harness: "claude", model: "claude-opus-5" },
    ];
    expect(runnableRecents(recents, claude, "claude", 4)).toEqual([{ harness: "claude", model: "claude-opus-5" }]);
  });

  test("the safe triangle holds a submenu while the pointer heads into it", () => {
    expect(insideTriangle({ x: 1, y: 1 }, { x: 0, y: 0 }, { x: 4, y: 0 }, { x: 0, y: 4 })).toBe(true);
    expect(insideTriangle({ x: 5, y: 5 }, { x: 0, y: 0 }, { x: 4, y: 0 }, { x: 0, y: 4 })).toBe(false);
    // A submenu to the left of the row: moving left and down toward it aims; moving right doesn't.
    const submenu = { left: 0, right: 100, top: 0, bottom: 200 };
    expect(aimingAt({ x: 150, y: 150 }, { x: 140, y: 155 }, submenu)).toBe(true);
    expect(aimingAt({ x: 150, y: 150 }, { x: 160, y: 150 }, submenu)).toBe(false);
    expect(aimingAt({ x: 150, y: 150 }, { x: 150, y: 150 }, submenu)).toBe(false);
    expect(aimingAt({ x: 150, y: 150 }, { x: 140, y: 155 }, { left: 0, right: 0, top: 0, bottom: 0 })).toBe(false);
  });

  test("the picker variant comes from ?picker=, then storage, else the current picker", () => {
    const globals = globalThis as Record<string, unknown>;
    const saved = globals.localStorage;
    try {
      globals.localStorage = { getItem: () => "columns" };
      expect(modelPickerVariant("?picker=cascade")).toBe("cascade");
      expect(modelPickerVariant("")).toBe("columns");
      expect(modelPickerVariant("?picker=bogus")).toBe("columns");
      globals.localStorage = { getItem: () => "bogus" };
      expect(modelPickerVariant("")).toBe("current");
      globals.localStorage = {
        getItem: () => {
          throw new Error("blocked");
        },
      };
      expect(modelPickerVariant("?picker=recents")).toBe("recents");
      expect(modelPickerVariant("")).toBe("current");
    } finally {
      globals.localStorage = saved;
    }
  });
});
