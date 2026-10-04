import { expect, test } from "bun:test";
import { mergeModelCatalog, sessionModels } from "./modelCatalog";

test("models acpmux probed (_acpmux/models) fill the harness list (_acpmux/harnesses)", () => {
  const names = { harnesses: { codex: { argv: ["codex-acp"] }, claude: { argv: ["claude"] } } };
  const probed = {
    harnesses: [
      { harness: "codex", kind: "acp", isDefault: true, models: [{ id: "gpt-6.1-sol", name: "GPT-6.1 Sol" }] },
      { harness: "peer/claude", kind: "claude-stdio", models: [{ id: "opus" }] },
    ],
  };
  const catalog = mergeModelCatalog(names, probed);
  expect(catalog.find((harness) => harness.id === "codex")?.models).toEqual([
    { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" },
  ]);
  expect(catalog.find((harness) => harness.id === "claude")?.models).toEqual([]);
  expect(catalog.find((harness) => harness.id === "peer/claude")?.models).toEqual([{ id: "opus", name: undefined }]);
  // A list that already carries its models (the mock daemon) keeps them.
  const mock = { harnesses: [{ id: "codex", name: "Codex", models: [{ id: "a", name: "A" }] }] };
  expect(mergeModelCatalog(mock, undefined)[0]?.models).toEqual([{ id: "a", name: "A" }]);
});

test("a session whose harness has no catalog yet lists the models its model option offers", () => {
  expect(
    sessionModels([], {
      harness: "codex",
      configOptions: [
        { id: "model", category: "model", currentValue: "b", options: [{ value: "a", name: "A" }, { value: "b" }] },
      ],
    }),
  ).toEqual([
    { id: "a", name: "A" },
    { id: "b", name: "b" },
  ]);
  expect(
    sessionModels([{ id: "codex", name: "Codex", models: [{ id: "x", name: "X" }] }], { harness: "codex" }),
  ).toEqual([{ id: "x", name: "X" }]);
  expect(sessionModels([], { harness: "codex" })).toEqual([]);
});

test("a model acpmux reports unavailable says so in the picker, with its reason", () => {
  const probed = {
    harnesses: [
      {
        harness: "codex",
        models: [{ id: "gpt-5.5", name: "GPT-5.5", unavailable: "Image web search is not supported." }],
      },
    ],
  };
  const catalog = mergeModelCatalog({ harnesses: { codex: {} } }, probed);
  expect(sessionModels(catalog, { harness: "codex" })).toEqual([
    { id: "gpt-5.5", name: "GPT-5.5 · unavailable: Image web search is not supported." },
  ]);
});

// plans/cmux-next/acp-usability.md, blocker 8: Gemini's probe failed ("API key is missing"), the
// picker still offered it, and a pick failed after 5.1 s.
test("a harness acpmux cannot start carries its reason, from its launcher check or its model probe", () => {
  const names = {
    harnesses: {
      codex: {},
      gemini: { unavailable: "gemini: not found on PATH" },
      opencode: {},
    },
  };
  const probed = {
    harnesses: [
      { harness: "codex", models: [{ id: "gpt-6-astra" }] },
      {
        harness: "opencode",
        unavailable: "API key is missing",
        models: [{ id: "default", name: "default (agent's choice)" }],
      },
    ],
  };
  const catalog = mergeModelCatalog(names, probed);
  expect(catalog.find((harness) => harness.id === "gemini")?.unavailable).toBe("gemini: not found on PATH");
  expect(catalog.find((harness) => harness.id === "opencode")?.unavailable).toBe("API key is missing");
  expect(catalog.find((harness) => harness.id === "codex")?.unavailable).toBeUndefined();
});
