import { expect, test } from "bun:test";
import { BUNDLED_MODEL_CATALOG, buildPickerCatalog } from "../src/agent-session/acpmux/modelCatalogData";
import { relevantModelSections } from "../src/agent-session/acpmux/relevantModels";
import { retryModelSections } from "../src/agent-session/acpmux/conversation/retryModelSections";
import { topModelsFor } from "../src/agent-session/acpmux/topModels";

// Leo's requested releases are an independent behavioral oracle, not a copy of the source being tested.
const requested = {
  claude: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"],
  codex: ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6.1-luna", "gpt-6-astra"],
};
const ids = (models: readonly { id: string }[]) => models.map((model) => model.id);

for (const [harnessId, expected] of Object.entries(requested)) {
  test(`${harnessId}: bundled fallback, composer, retry and curated menu agree on current families`, () => {
    const harness = BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === harnessId)!;
    expect(topModelsFor(harnessId)).toEqual(expected);
    for (const id of expected) expect(ids(harness.models)).toContain(id);
    const composer = relevantModelSections(harness.models, undefined);
    const retry = retryModelSections(harness.models, undefined, harness.name);
    expect(ids(composer.shown).slice(0, expected.length)).toEqual(expected);
    expect(ids(retry.latest)).toEqual(ids(composer.shown));
    expect(ids(retry.more)).toEqual(ids(composer.more));
  });
}

test("all model menus preserve the account's explicit list and order without a fixed count", () => {
  const models = Array.from({ length: 7 }, (_, index) => ({ id: `account-model-${index}`, name: `Account ${index}` }));
  for (const top of [[models[1]!.id, models[0]!.id], ids(models).reverse()]) {
    const catalog = buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      acpmux: [{ id: "codex", family: "codex", name: "Codex", models, topModels: top }],
      session: { harness: "codex", model: "gpt-6-sol" },
    });
    const harness = catalog.harnesses.find((entry) => entry.id === "codex")!;
    const rows = harness.models.map((model) => ({ ...model, name: model.shortName || model.name }));
    expect(ids(relevantModelSections(rows, harness.topModels).shown)).toEqual(top);
    expect(ids(retryModelSections(rows, "gpt-6-sol", harness.name, harness.topModels).latest)).toEqual(top);
  }
});

test("a later release and a new harness family remain visible without changing a pinned shortlist", () => {
  const models = [
    { id: "gpt-6-luna", name: "GPT-6 Luna", family: "Luna" },
    { id: "gpt-6.1-luna", name: "GPT-6.1 Luna", family: "Luna" },
    { id: "gpt-6.2-luna", name: "GPT-6.2 Luna", family: "Luna" },
    { id: "new-family-1", name: "New Family 1", family: "New Family" },
  ];
  const composer = relevantModelSections(models, undefined);
  const retry = retryModelSections(models, "gpt-6-luna", "Codex");
  expect(ids(composer.shown)).toEqual(["gpt-6.2-luna", "new-family-1"]);
  expect(ids(retry.latest)).toEqual(ids(composer.shown));
  expect(ids(retry.more)).toContain("gpt-6-luna");
});
