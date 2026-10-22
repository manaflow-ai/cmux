// The model menu's alias fold (PR #24224, Codex review at 7ab8d7b0): Claude Code names its `opus`
// alias "Opus 5.5", the same model as the catalog release claude-opus-5-5, so the picker lists them
// as one row. That fold must not change what the row offers or which row is the running one:
// - the alias keeps what the harness declares for it and the user's overrides of it (cmux.json
//   `agentPane.models.overrides["<harness>/opus"]`), on top of the release's catalog metadata;
// - a session that reports running the pinned release (`summary.model`) with no model option keeps
//   that release's row, so the running model is listed and checked.
import { expect, test } from "bun:test";
import { BUNDLED_MODEL_CATALOG, buildPickerCatalog } from "../src/agent-session/acpmux/modelCatalogData";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

/** A Claude Code profile the catalog does not map (Leo's claude-sr2), listing `opus` and the release. */
const profile = (models: { id: string; name: string }[]): AcpmuxSnapshot["catalog"] =>
  [{ id: "claude-sr2", name: "Claude Code", family: "claude-sr2", models }] as AcpmuxSnapshot["catalog"];

const modelsOf = (catalog: ReturnType<typeof buildPickerCatalog>) =>
  catalog.harnesses.find((harness) => harness.id === "claude-sr2")!.models;

test("a folded alias keeps the user's overrides of it", () => {
  const models = modelsOf(
    buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      user: { overrides: { "claude-sr2/opus": { fast: false, efforts: ["low"], defaultEffort: "low" } } },
      acpmux: profile([{ id: "opus", name: "Opus 5.5" }]),
    }),
  );
  const opus = models.find((model) => model.id === "opus");
  expect(opus, models.map((model) => model.id).join(", ")).toBeDefined();
  expect({ fast: opus!.fast, efforts: opus!.efforts, defaultEffort: opus!.defaultEffort }).toEqual({
    fast: false,
    efforts: ["low"],
    defaultEffort: "low",
  });
  // Still the release's catalog row underneath: one row for Opus 5.5.
  expect(opus!.release).toBe("claude-opus-5-5");
  expect(models.filter((model) => model.shortName === "Opus 5.5")).toHaveLength(1);
});

test("a session reporting the pinned release with no model option keeps that release's row", () => {
  const models = modelsOf(
    buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      acpmux: profile([
        { id: "opus", name: "Opus 5.5" },
        { id: "claude-opus-5-5", name: "Opus 5.5" },
      ]),
      session: { harness: "claude-sr2", model: "claude-opus-5-5" },
    }),
  );
  const ids = models.map((model) => model.id);
  expect(ids, ids.join(", ")).toContain("claude-opus-5-5");
  // ...and Opus 5.5 is still listed once.
  expect(
    models.filter((model) => model.shortName === "Opus 5.5"),
    ids.join(", "),
  ).toHaveLength(1);
});

// Codex review at 850d3746: the running release took the alias's place but dropped what the user
// set for the alias, so a chat on Opus 5.5 offered Fast and every effort again.
test("the running release keeps the folded alias's overrides, and stays the checked row", () => {
  const models = modelsOf(
    buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      user: { overrides: { "claude-sr2/opus": { fast: false, efforts: ["low"], defaultEffort: "low" } } },
      acpmux: profile([
        { id: "opus", name: "Opus 5.5" },
        { id: "claude-opus-5-5", name: "Opus 5.5" },
      ]),
      session: { harness: "claude-sr2", model: "claude-opus-5-5" },
    }),
  );
  const ids = models.map((model) => model.id);
  const running = models.find((model) => model.id === "claude-opus-5-5");
  expect(running, ids.join(", ")).toBeDefined();
  expect(ids, "the alias folds into it").not.toContain("opus");
  expect({ fast: running!.fast, efforts: running!.efforts, defaultEffort: running!.defaultEffort }).toEqual({
    fast: false,
    efforts: ["low"],
    defaultEffort: "low",
  });
});

// Codex review at a3f9e52c: the session's options then marked that row Fast-capable and gave it every
// effort the adapter lists, because a row with no efforts read as one the catalog does not describe.
test("the session's fast and effort options do not undo what the alias's declaration or override disables", () => {
  const live = [
    {
      id: "fast-mode",
      name: "Fast mode",
      currentValue: "off",
      options: [
        { value: "off", name: "Off" },
        { value: "on", name: "On" },
      ],
    },
    {
      id: "effort",
      name: "Effort",
      category: "thought_level",
      currentValue: "high",
      options: [
        { value: "low", name: "Low" },
        { value: "medium", name: "Medium" },
        { value: "high", name: "High" },
      ],
    },
  ] as NonNullable<Parameters<typeof buildPickerCatalog>[0]["session"]>["configOptions"];
  const session = { harness: "claude-sr2", model: "claude-opus-5-5", configOptions: live };
  const disabled = { fast: false, efforts: [] };
  const fromOverride = modelsOf(
    buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      user: { overrides: { "claude-sr2/opus": disabled } },
      acpmux: profile([
        { id: "opus", name: "Opus 5.5" },
        { id: "claude-opus-5-5", name: "Opus 5.5" },
      ]),
      session,
    }),
  );
  const fromDeclaration = modelsOf(
    buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      acpmux: profile([
        { id: "opus", name: "Opus 5.5", ...disabled } as { id: string; name: string },
        { id: "claude-opus-5-5", name: "Opus 5.5" },
      ]),
      session,
    }),
  );
  for (const [source, models] of [
    ["override", fromOverride],
    ["declaration", fromDeclaration],
  ] as const) {
    const running = models.find((model) => model.id === "claude-opus-5-5");
    expect(running, `${source}: ${models.map((model) => model.id).join(", ")}`).toBeDefined();
    expect({ source, fast: running!.fast, efforts: running!.efforts }).toEqual({ source, fast: false, efforts: [] });
  }
});
