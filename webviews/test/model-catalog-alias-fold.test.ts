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

test("a renamed running release stays in the harness-reported alias shortlist", () => {
  const joined = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    user: { overrides: { "claude-sr2/opus": { name: "My Opus", shortName: "My Opus" } } },
    acpmux: profile([
      { id: "opus", name: "Opus 5.5" },
      { id: "claude-opus-5-5", name: "Opus 5.5" },
    ]),
    session: {
      harness: "claude-sr2",
      model: "claude-opus-5-5",
      configOptions: [
        {
          id: "model",
          name: "Model",
          category: "model",
          currentValue: "claude-opus-5-5",
          options: [{ value: "opus", name: "Opus 5.5" }],
        },
      ],
    },
  });
  expect(joined.harnesses.find((harness) => harness.id === "claude-sr2")!.topModels).toEqual(["claude-opus-5-5"]);
});

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

// Codex review at 6638fbc2: a direct session (direct.ts) has no model option and reports the release
// it runs (`summary.model`), while the live Claude probe lists only the bare `opus` alias. The menu
// showed an `opus` row and no checked row, so picking the apparent current model chose the alias.
test("a direct session running the release the probe lists only as an alias shows that release, checked", () => {
  for (const [harness, acpmux] of [
    ["claude", [{ id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus 5.5" }] }]],
    ["claude-sr2", profile([{ id: "opus", name: "Opus 5.5" }])],
  ] as const) {
    const catalog = buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      user: { overrides: { [`${harness}/opus`]: { fast: false, efforts: [] } } },
      acpmux: acpmux as AcpmuxSnapshot["catalog"],
      session: { harness, model: "claude-opus-5-5" },
    });
    const models = catalog.harnesses.find((entry) => entry.id === harness)!.models;
    const ids = models.map((model) => model.id);
    expect(ids, `${harness}: ${ids.join(", ")}`).toContain("claude-opus-5-5");
    expect(ids, `${harness}: the alias folds into it`).not.toContain("opus");
    expect(
      models.filter((model) => model.shortName === "Opus 5.5"),
      `${harness}: ${ids.join(", ")}`,
    ).toHaveLength(1);
    const running = models.find((model) => model.id === "claude-opus-5-5")!;
    expect({ harness, release: running.release, fast: running.fast, efforts: running.efforts }).toEqual({
      harness,
      release: undefined,
      fast: false,
      efforts: [],
    });
  }
});

// Codex review at a14ff113 and the sweep after it: every override field, on the paths this PR added
// (the alias fold, the running release, the session's options), for a profile the catalog does not
// map (claude-sr2, whose kin is Claude Code) and for the catalog's own Claude Code.
const fastAndEffort = [
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
    options: ["low", "medium", "high", "xhigh", "max"].map((value) => ({ value, name: value })),
  },
] as NonNullable<NonNullable<Parameters<typeof buildPickerCatalog>[0]["session"]>["configOptions"]>;

const modelOption = [
  {
    id: "model",
    name: "Model",
    category: "model",
    currentValue: "claude-opus-5-5",
    options: [{ value: "claude-opus-5-5", name: "Opus 5.5" }],
  },
] as NonNullable<NonNullable<Parameters<typeof buildPickerCatalog>[0]["session"]>["configOptions"]>;

const rowsFor = (
  harness: string,
  probe: { id: string; name: string }[],
  overrides: Record<string, unknown>,
  session: { model?: string; configOptions?: typeof fastAndEffort } = { model: "claude-opus-5-5" },
) =>
  buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    user: { overrides },
    acpmux: (harness === "claude"
      ? [{ id: "claude", name: "Claude Code", models: probe }]
      : profile(probe)) as AcpmuxSnapshot["catalog"],
    session: { harness, ...session },
  }).harnesses.find((entry) => entry.id === harness)!.models;

const opusRows = (models: ReturnType<typeof rowsFor>) =>
  models.filter((model) => model.shortName === "Opus 5.5" || model.id === "claude-opus-5-5" || model.id === "opus");

for (const harness of ["claude-sr2", "claude"])
  for (const key of [`${harness}/opus`, "*/opus", `${harness}/claude-opus-5-5`])
    test(`${harness}: hiding ${key} keeps the running release out, as before the fold`, () => {
      // Alias-only probe, a direct session that reports the release it runs (no model option).
      const models = rowsFor(harness, [{ id: "opus", name: "Opus 5.5" }], { [key]: { hidden: true } });
      const shown = opusRows(models).map((model) => model.id);
      // Hiding the alias hides the model; hiding the release leaves the bare alias the harness lists.
      expect(shown, models.map((model) => model.id).join(", ")).toEqual(
        key.endsWith("/claude-opus-5-5") ? ["opus"] : [],
      );
    });

for (const harness of ["claude-sr2", "claude"])
  test(`${harness}: hiding an alias also hides a simultaneously reported release`, () => {
    const models = rowsFor(
      harness,
      [
        { id: "opus", name: "Opus 5.5" },
        { id: "claude-opus-5-5", name: "Opus 5.5" },
      ],
      { [`${harness}/opus`]: { hidden: true } },
      { model: "claude-opus-5-5", configOptions: modelOption },
    );
    expect(
      opusRows(models).map((model) => model.id),
      models.map((model) => model.id).join(", "),
    ).toEqual([]);
  });

test("an alias the user renamed still folds into its release: one row", () => {
  const models = rowsFor(
    "claude-sr2",
    [
      { id: "opus", name: "Opus 5.5" },
      { id: "claude-opus-5-5", name: "Opus 5.5" },
    ],
    { "claude-sr2/opus": { name: "My Opus", shortName: "My Opus" } },
  );
  const rows = opusRows(models).concat(models.filter((model) => model.name === "My Opus"));
  expect([...new Set(rows.map((model) => model.id))], models.map((model) => model.id).join(", ")).toEqual([
    "claude-opus-5-5",
  ]);
  expect(rows[0]!.shortName).toBe("My Opus");
});

test("a release the user renamed still takes the alias the harness names as it: one row", () => {
  const models = rowsFor(
    "claude",
    [{ id: "opus", name: "Opus 5.5" }],
    {
      "claude/claude-opus-5-5": { name: "Big Opus", shortName: "Big Opus" },
    },
    {},
  );
  const rows = models.filter((model) => ["opus", "claude-opus-5-5"].includes(model.id) || model.release);
  expect(
    rows
      .filter((model) => model.release === "claude-opus-5-5" || model.id === "claude-opus-5-5")
      .map((model) => model.id),
    models.map((model) => model.id).join(", "),
  ).toEqual(["opus"]);
});

for (const [harness, probe] of [
  ["claude", [{ id: "opus", name: "Opus 5.5" }]],
  ["claude", []],
  ["claude-sr2", [{ id: "opus", name: "Opus 5.5" }]],
  [
    "claude-sr2",
    [
      { id: "opus", name: "Opus 5.5" },
      { id: "claude-opus-5-5", name: "Opus 5.5" },
    ],
  ],
] as const)
  for (const key of [`${harness}/opus`, "*/opus", `${harness}/claude-opus-5-5`])
    test(`${harness} (${probe.map((model) => model.id).join(" + ") || "no probe"}): ${key} set to no fast and no levels holds against the session's options`, () => {
      const models = rowsFor(
        harness,
        [...probe],
        { [key]: { fast: false, efforts: [] } },
        {
          model: "claude-opus-5-5",
          configOptions: fastAndEffort,
        },
      );
      const running = models.find((model) => model.id === "claude-opus-5-5");
      expect(running, models.map((model) => model.id).join(", ")).toBeDefined();
      expect({ fast: running!.fast, efforts: running!.efforts }).toEqual({ fast: false, efforts: [] });
      expect(running!.own).toEqual({ efforts: true, fast: true });
    });
