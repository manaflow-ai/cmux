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
// picker still offered it, and a pick failed after 5.1 s. The shapes are acpmux's: a launcher
// check is `unavailable` on the _acpmux/harnesses entry, a failed model probe is `probeError` on
// both the _acpmux/harnesses entry and the _acpmux/models entry (hq48-acpmux-warm d6dda95c61d).
test("a harness acpmux cannot start carries its reason, from its launcher check or its model probe", () => {
  const names = {
    harnesses: {
      codex: { family: "codex" },
      deepseek: { unavailable: "dsh: not found on PATH" },
      gemini: { family: "gemini", probeError: "Gemini API key is missing or not configured." },
      opencode: { family: "opencode" },
    },
  };
  const probed = {
    harnesses: [
      { harness: "codex", models: [{ id: "gpt-6-astra" }] },
      {
        harness: "gemini",
        probeError: "Gemini API key is missing or not configured.",
        models: [{ id: "default", name: "default (agent's choice)" }],
      },
      {
        harness: "opencode",
        probeError: "the model probe timed out after 60 s",
        models: [{ id: "default", name: "default (agent's choice)" }],
      },
    ],
  };
  const catalog = mergeModelCatalog(names, probed);
  const reason = (id: string) => catalog.find((harness) => harness.id === id)?.unavailable;
  expect(reason("deepseek")).toBe("dsh: not found on PATH");
  expect(reason("gemini")).toBe("Gemini API key is missing or not configured.");
  // Only the models list says so (a daemon that reports the probe there first).
  expect(reason("opencode")).toBe("the model probe timed out after 60 s");
  expect(reason("codex")).toBeUndefined();
  // The probe failure alone, before _acpmux/models answers.
  expect(mergeModelCatalog(names, undefined).find((harness) => harness.id === "gemini")?.unavailable).toBe(
    "Gemini API key is missing or not configured.",
  );
});
