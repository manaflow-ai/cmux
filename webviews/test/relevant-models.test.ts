import { expect, test } from "bun:test";
import { relevantModelSections } from "../src/agent-session/acpmux/relevantModels";

const ids = (rows: readonly { id: string }[]) => rows.map((row) => row.id);
const models = Array.from({ length: 12 }, (_, index) => ({ id: `model-${index}`, name: `Model ${index}` }));

test("the harness's menu order wins over catalog order, without a fixed count", () => {
  for (const top of [["model-1", "model-0"], ids(models).reverse()]) {
    const result = relevantModelSections(models, top);
    expect(ids(result.shown)).toEqual(top);
    expect(ids(result.more)).toEqual(ids(models).filter((id) => !top.includes(id)));
  }
});

test("the harness's menu includes each model once and leaves its other models folded", () => {
  const result = relevantModelSections(models, ["model-2", "model-2", "model-8"]);
  expect(ids(result.shown)).toEqual(["model-2", "model-8"]);
  expect(ids(result.more)).toContain("model-0");
});

test("a provider alias names the same grouped row and unavailable models stay folded", () => {
  const grouped = {
    id: "provider-a/opus",
    name: "Opus",
    offers: [
      { id: "provider-a/opus", release: "opus-5" },
      { id: "provider-b/opus", unavailable: "Signed out" },
    ],
  };
  const blocked = { id: "blocked", name: "Blocked", unavailable: "No access" };
  const result = relevantModelSections(
    [grouped, blocked, ...models],
    ["opus-5", "provider-b/opus", "blocked", "absent"],
  );
  expect(result.shown).toEqual([grouped]);
  expect(result.more).toEqual([blocked, ...models]);
});

// https://github.com/manaflow-ai/cmux/issues/29915: Codex reports its whole live list as its menu,
// so its tab listed 13 models flat while Claude's folded the rest under Legacy models.
test("a harness menu that lists older versions of a catalog family folds them, keeping variants", () => {
  const catalog = [
    { id: "gpt-6.1-sol", name: "GPT-6.1 Sol", family: "Sol" },
    { id: "gpt-6.1-terra", name: "GPT-6.1 Terra", family: "Terra" },
    { id: "gpt-6-sol", name: "GPT-6 Sol", family: "Sol" },
    { id: "gpt-5.6-terra", name: "GPT-5.6 Terra", family: "Terra" },
    { id: "gpt-6-astra", name: "GPT-6 Astra", family: "Astra" },
    { id: "gpt-5.5", name: "GPT-5.5", family: "GPT" },
    { id: "opus[1m]", name: "Opus 5.5 · 1M context", family: "Opus", release: "claude-opus-5-5" },
    { id: "opus", name: "Opus 5.5", family: "Opus", release: "claude-opus-5-5" },
    { id: "plain", name: "Plain", family: "Opus" },
  ];
  const result = relevantModelSections(catalog, ids(catalog));
  expect(ids(result.shown)).toEqual([
    "gpt-6.1-sol",
    "gpt-6.1-terra",
    "gpt-6-astra",
    "gpt-5.5",
    "opus[1m]",
    "opus",
    "plain",
  ]);
  expect(ids(result.more)).toEqual(["gpt-6-sol", "gpt-5.6-terra"]);
});

test("a vendor-wide family folds within one product line only", () => {
  const catalog = [
    { id: "openai/gpt-6.1-sol", name: "GPT-6.1 Sol", family: "OpenAI" },
    { id: "openai/gpt-6-astra", name: "GPT-6 Astra", family: "OpenAI" },
    { id: "openai/gpt-5.4-mini", name: "GPT-5.4 mini", family: "OpenAI" },
    { id: "openai/gpt-6-sol", name: "GPT-6 Sol", family: "OpenAI" },
    { id: "gpt-5.6", name: "GPT-5.6", family: "Sol" },
    { id: "gpt-6-sol", name: "GPT-6 Sol", family: "Sol" },
  ];
  const result = relevantModelSections(catalog, ids(catalog));
  expect(ids(result.shown)).toEqual([
    "openai/gpt-6.1-sol",
    "openai/gpt-6-astra",
    "openai/gpt-5.4-mini",
    "gpt-5.6",
    "gpt-6-sol",
  ]);
  expect(ids(result.more)).toEqual(["openai/gpt-6-sol"]);
});

test("the running model keeps its row and a dated snapshot never folds its alias", () => {
  const catalog = [
    { id: "gpt-6.1-terra", name: "GPT-6.1 Terra", family: "Terra" },
    { id: "gpt-5.6-terra", name: "GPT-5.6 Terra", family: "Terra" },
    { id: "claude-opus-4-5-20251101", name: "", family: "Opus" },
    { id: "claude-opus-4-5", name: "", family: "Opus" },
  ];
  const result = relevantModelSections(catalog, ids(catalog), "gpt-5.6-terra");
  expect(ids(result.shown)).toEqual(ids(catalog));
  expect(ids(relevantModelSections(catalog, ids(catalog)).more)).toEqual(["gpt-5.6-terra"]);
});

test("without a harness menu, newest provider families are inferred without model-name allowlists", () => {
  const catalog = [
    { id: "gpt-6-sol", name: "GPT-6-Sol" },
    { id: "gpt-6.1-sol", name: "GPT-6.1-Sol" },
    { id: "gpt-6-astra", name: "GPT-6-Astra" },
    { id: "gpt-5.6-terra", name: "GPT-5.6-Terra" },
    { id: "gpt-6.1-terra", name: "GPT-6.1-Terra" },
    { id: "gpt-6-luna", name: "GPT-6-Luna" },
    { id: "gpt-6.1-luna", name: "GPT-6.1-Luna" },
  ];
  expect(ids(relevantModelSections(catalog, undefined).shown)).toEqual([
    "gpt-6.1-sol",
    "gpt-6.1-terra",
    "gpt-6.1-luna",
    "gpt-6-astra",
  ]);
});

test("catalog family metadata is authoritative and context variants do not duplicate its newest row", () => {
  const catalog = [
    { id: "wide[1m]", name: "Opus 5.5 · 1M context", family: "Opus" },
    { id: "opus-old", name: "Opus 4.1", family: "Opus" },
    { id: "opus", name: "Opus 5.5", family: "Opus" },
    { id: "sonnet", name: "Sonnet 5.5", family: "Sonnet" },
    { id: "haiku", name: "Haiku 5.5", family: "Haiku" },
    { id: "fable", name: "Fable 5.1", family: "Fable" },
  ];
  expect(ids(relevantModelSections(catalog, undefined).shown)).toEqual(["opus", "sonnet", "haiku", "fable"]);
});

test("a different provider's same family name remains distinct", () => {
  const catalog = [
    { id: "openrouter/qwen/coder-3", name: "Coder 3", family: "Coder" },
    { id: "openrouter/mistral/coder-2", name: "Coder 2", family: "Coder" },
  ];
  expect(relevantModelSections(catalog, undefined).shown).toEqual(catalog);
});
