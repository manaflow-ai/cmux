import { describe, expect, test } from "bun:test";
import {
  BUNDLED_MODEL_CATALOG,
  applyUserLayer,
  buildPickerCatalog,
  readModelCatalog,
  type ModelCatalog,
} from "./modelCatalogData";
import { catalogModel, normalizeCatalog } from "./direct";

const CATALOG: ModelCatalog = {
  schemaVersion: 1,
  generatedAt: "2026-10-06T18:00:00.000Z",
  source: "live",
  harnesses: [
    {
      id: "claude",
      name: "Claude Code",
      brand: "claude",
      families: ["claude"],
      modelSource: "catalog",
      defaultModel: "claude-sonnet-5",
      models: [
        {
          id: "claude-opus-5-5",
          ref: "anthropic/claude-opus-5-5",
          name: "Claude Opus 5.5",
          shortName: "Opus 5.5",
          family: "Opus",
          provider: "anthropic",
          efforts: ["low", "medium", "high", "xhigh", "max"],
          fast: true,
          aliases: ["opus"],
        },
        {
          id: "claude-sonnet-5",
          ref: "anthropic/claude-sonnet-5",
          name: "Claude Sonnet 5",
          shortName: "Sonnet 5",
          family: "Sonnet",
          provider: "anthropic",
        },
      ],
    },
    {
      id: "codex",
      name: "Codex",
      brand: "openai",
      families: ["codex"],
      modelSource: "catalog",
      models: [
        {
          id: "gpt-5.5",
          ref: "openai/gpt-5.5",
          name: "GPT-5.5",
          shortName: "GPT-5.5",
          efforts: ["low", "medium"],
          defaultEffort: "medium",
        },
      ],
    },
    {
      id: "opencode",
      name: "OpenCode",
      brand: "opencode",
      families: ["opencode"],
      modelSource: "probe",
      models: [],
    },
    {
      id: "vercel-ai-gateway",
      name: "Vercel AI Gateway",
      brand: "vercel",
      families: ["vercel-ai-gateway"],
      modelSource: "catalog",
      models: [{ id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5", shortName: "Sonnet 5" }],
    },
  ],
  models: {
    "anthropic/claude-opus-5-5": {
      name: "Claude Opus 5.5",
      contextWindow: 1000000,
      reasoning: true,
      input: ["text", "image"],
    },
    "anthropic/claude-sonnet-5": { name: "Claude Sonnet 5", contextWindow: 1000000 },
    "openai/gpt-5.5": { name: "GPT-5.5", contextWindow: 1050000 },
  },
  providers: { anthropic: { name: "Anthropic" }, openai: { name: "OpenAI" } },
};

const ACPMUX = normalizeCatalog({
  harnesses: {
    "claude-sr": {
      family: "claude",
      models: [
        { id: "opus", name: "Opus" },
        { id: "claude-next-1", name: "Next 1" },
      ],
    },
    codex: { family: "codex", unavailable: "codex is not signed in", models: [] },
    opencode: {
      family: "opencode",
      models: [{ id: "anthropic/claude-sonnet-5" }, { id: "ollama/qwen3-coder", name: "qwen3-coder" }],
    },
    "corp-claude": { family: "claude", models: [] },
    acme: {
      family: "acme",
      displayName: "Acme Agent",
      icon: "/icons/acme.svg",
      models: [
        {
          id: "acme-1",
          name: "Acme One",
          shortName: "One",
          efforts: ["low", "high"],
          fast: true,
          contextWindow: 64000,
        },
      ],
    },
  },
});

describe("buildPickerCatalog", () => {
  const picker = buildPickerCatalog({ catalog: CATALOG, acpmux: ACPMUX });
  const byId = (id: string) => picker.harnesses.find((harness) => harness.id === id)!;

  test("catalog harnesses come first in catalog order, then harnesses no catalog entry covers", () => {
    expect(picker.harnesses.map((harness) => harness.id)).toEqual([
      "claude",
      "codex",
      "opencode",
      "vercel-ai-gateway",
      "acme",
    ]);
    expect(picker.provisional).toBe(false);
  });

  test("a catalog harness maps to its family's acpmux harness; a profile of a covered family joins it", () => {
    expect(byId("claude")).toMatchObject({
      name: "Claude Code",
      brand: "claude",
      acpmuxHarness: "claude-sr",
      installed: true,
    });
    // corp-claude (family claude) joins Claude Code instead of listing on its own.
    expect(picker.harnesses.some((harness) => harness.id === "corp-claude")).toBe(false);
  });

  test("catalog models list in order; an alias the harness probed maps to its model; new probed models are added", () => {
    expect(byId("claude").models.map((model) => model.id)).toEqual([
      "claude-opus-5-5",
      "claude-sonnet-5",
      "claude-next-1",
    ]);
    expect(byId("claude").models[0]).toMatchObject({
      name: "Claude Opus 5.5",
      shortName: "Opus 5.5",
      family: "Opus",
      providerName: "Anthropic",
      efforts: ["low", "medium", "high", "xhigh", "max"],
      fast: true,
      contextWindow: 1000000,
      reasoning: true,
      input: ["text", "image"],
    });
    expect(byId("claude").models[0]?.searchText).toContain("opus");
    expect(byId("claude").models[2]).toMatchObject({ name: "Next 1", efforts: [], fast: false });
  });

  test("acpmux reasons are kept; a catalog harness acpmux lacks lists as not installed", () => {
    expect(byId("codex")).toMatchObject({
      unavailable: "codex is not signed in",
      installed: true,
      acpmuxHarness: "codex",
    });
    expect(byId("vercel-ai-gateway")).toMatchObject({ installed: false, acpmuxHarness: null });
    expect(byId("vercel-ai-gateway").unavailable).toBeUndefined();
  });

  test("probe harnesses list what acpmux probed, described by ref when the catalog knows it", () => {
    expect(
      byId("opencode").models.map((model) => [model.id, model.name, model.contextWindow, model.providerName]),
    ).toEqual([
      ["anthropic/claude-sonnet-5", "Claude Sonnet 5", 1000000, "Anthropic"],
      ["ollama/qwen3-coder", "qwen3-coder", undefined, undefined],
    ]);
  });

  test("an uncatalogued profile takes its declared name, icon and model metadata", () => {
    expect(byId("acme")).toMatchObject({
      name: "Acme Agent",
      brand: null,
      iconUrl: "/icons/acme.svg",
      acpmuxHarness: "acme",
    });
    expect(byId("acme").models[0]).toMatchObject({
      id: "acme-1",
      name: "Acme One",
      shortName: "One",
      efforts: ["low", "high"],
      fast: true,
      contextWindow: 64000,
    });
  });

  test("the session's live options win for effort and fast mode", () => {
    const live = buildPickerCatalog({
      catalog: CATALOG,
      acpmux: ACPMUX,
      session: {
        harness: "claude-sr",
        configOptions: [
          {
            id: "effort",
            name: "Effort",
            category: "thought_level",
            currentValue: "high",
            options: [
              { value: "high", name: "High" },
              { value: "max", name: "Max" },
            ],
          },
        ] as never,
      },
    });
    expect(live.harnesses[0]?.models[1]?.efforts).toEqual(["high", "max"]);
    expect(live.harnesses[1]?.models[0]?.efforts).toEqual(["low", "medium"]);
  });

  test("the user layer wins over declared metadata and the catalog, and hides harnesses with their profiles", () => {
    const user = {
      harnesses: {
        "vercel-ai-gateway": { hidden: true },
        claude: { name: "Claude (work)" },
        acme: { hidden: true },
      },
      overrides: {
        "claude/claude-opus-5-5": { name: "Opus", defaultEffort: "max" },
        "claude/claude-sonnet-5": { hidden: true },
        "opencode/ollama/qwen3-coder": { name: "Qwen3 Coder (local)", contextWindow: 131072 },
        "codex/gpt-6-local": { name: "GPT local" },
        "*/claude-next-1": { hidden: true },
        broken: { hidden: true },
      },
    };
    const layered = buildPickerCatalog({ catalog: CATALOG, acpmux: ACPMUX, user });
    expect(layered.harnesses.map((harness) => harness.id)).toEqual(["claude", "codex", "opencode"]);
    expect(layered.harnesses[0]).toMatchObject({ name: "Claude (work)" });
    expect(layered.harnesses[0]?.models.map((model) => [model.id, model.name, model.defaultEffort])).toEqual([
      ["claude-opus-5-5", "Opus", "max"],
    ]);
    expect(layered.harnesses[1]?.models.map((model) => model.id)).toEqual(["gpt-5.5", "gpt-6-local"]);
    expect(layered.harnesses[2]?.models[1]).toMatchObject({
      name: "Qwen3 Coder (local)",
      contextWindow: 131072,
    });
    expect(applyUserLayer(CATALOG, user).diagnostics).toEqual([
      { path: "agentPane.models.overrides.broken", message: 'expected "<harness>/<model>": {…}' },
    ]);
  });
});

describe("catalog inputs", () => {
  test("readModelCatalog accepts schema 1 and refuses anything else", () => {
    expect(readModelCatalog(CATALOG)?.harnesses.length).toBe(4);
    expect(readModelCatalog({ ...CATALOG, schemaVersion: 2 })).toBeUndefined();
    expect(readModelCatalog(null)).toBeUndefined();
    expect(readModelCatalog({ ...CATALOG, harnesses: [{ id: 1 }, ...CATALOG.harnesses] })?.harnesses.length).toBe(4);
  });

  test("the bundled snapshot is a usable catalog with the five harnesses", () => {
    expect(BUNDLED_MODEL_CATALOG.delivery).toBe("bundled");
    expect(BUNDLED_MODEL_CATALOG.harnesses.map((harness) => harness.id)).toEqual([
      "claude",
      "codex",
      "opencode",
      "pi",
      "vercel-ai-gateway",
    ]);
    const offline = buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      acpmux: [],
      provisional: true,
    });
    expect(offline.provisional).toBe(true);
    expect(offline.harnesses[0]?.models.length).toBeGreaterThan(0);
  });

  test("declared model metadata survives normalization", () => {
    expect(
      catalogModel({
        id: "m",
        name: "M",
        shortName: "m",
        efforts: ["low", 3],
        fast: true,
        contextWindow: 10,
        family: "F",
      }),
    ).toEqual({
      id: "m",
      name: "M",
      shortName: "m",
      efforts: ["low"],
      fast: true,
      contextWindow: 10,
      family: "F",
    });
  });
});
