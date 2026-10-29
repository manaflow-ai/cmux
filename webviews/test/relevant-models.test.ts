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
    "gpt-6-astra",
    "gpt-6.1-terra",
    "gpt-6.1-luna",
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
