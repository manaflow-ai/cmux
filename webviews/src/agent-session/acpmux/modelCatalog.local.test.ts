import { expect, test } from "bun:test";
import { mergeModelCatalog } from "./modelCatalog";

for (const olderHost of [false, true]) {
  test(`daemon fallback identities stay unverified through the wire join (older host: ${olderHost})`, async () => {
    const { buildPickerCatalog, BUNDLED_MODEL_CATALOG } = await import("./modelCatalogData");
    const fallback = BUNDLED_MODEL_CATALOG.harnesses.find((harness) => harness.id === "codex")!.models;
    const hostCatalog = structuredClone(BUNDLED_MODEL_CATALOG);
    if (olderHost)
      for (const harness of hostCatalog.harnesses)
        harness.models = harness.models.filter((model) => !["gpt-6.1-terra", "gpt-6.1-luna"].includes(model.id));
    for (const id of ["codex", "codex-sr"]) {
      const join = (topModels?: string[], declared = false, current?: string) => {
        const acpmux = mergeModelCatalog(
          { harnesses: [{ id, family: id }] },
          {
            harnesses: [
              {
                harness: id,
                topModels,
                models: fallback.map((model) => ({ ...model, curated: true, declared })),
              },
            ],
          },
        );
        return buildPickerCatalog({
          catalog: hostCatalog,
          acpmux,
          session: { harness: id, model: current },
        })
          .harnesses.find((harness) => harness.id === id)!
          .models.map((model) => model.id);
      };
      expect(join()).not.toContain("gpt-6.1-terra");
      expect(join()).not.toContain("gpt-6.1-luna");
      expect(join(["gpt-6.1-terra"])).toContain("gpt-6.1-terra");
      expect(join(undefined, true)).toContain("gpt-6.1-terra");
      expect(join(undefined, false, "gpt-6.1-terra")).toContain("gpt-6.1-terra");
    }
  });
}

test("model routers are not harness choices, while cmux-prefixed launchers remain available", async () => {
  const { buildPickerCatalog, BUNDLED_MODEL_CATALOG } = await import("./modelCatalogData");
  const catalog = mergeModelCatalog(
    {
      harnesses: [
        { id: "cmux", name: "Cmux", kind: "cmux-router", family: "codex" },
        { id: "local-router", name: "Local router", kind: "local-coderouter" },
        { id: "cmux-codex", name: "cmux Codex", family: "codex", kind: "acp" },
      ],
    },
    {},
  );
  expect(catalog.filter((entry) => entry.pickable !== false).map((entry) => entry.id)).toEqual(["cmux-codex"]);
  const picker = buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: catalog });
  expect(picker.harnesses.filter((entry) => entry.pickable).map((entry) => entry.id)).not.toContain("cmux");
  expect(picker.harnesses.find((entry) => entry.id === "codex")?.acpmuxHarness).toBe("cmux-codex");
});

test("the picker uses only this machine's harness list and ignores peer model probes", () => {
  const catalog = mergeModelCatalog(
    { harnesses: [{ id: "claude", name: "Claude Code" }] },
    {
      harnesses: [
        { harness: "claude", models: [{ id: "local-opus", name: "Opus" }] },
        { harness: "claude", peer: "other-machine", models: [{ id: "remote-opus" }] },
        { harness: "peer-only-codex", peer: "other-machine", models: [{ id: "remote-gpt" }] },
        { harness: "unlisted-profile", models: [{ id: "unlisted-model" }] },
      ],
    },
  );
  expect(catalog.map((entry) => entry.id)).toEqual(["claude"]);
  expect(catalog[0]!.models.map((model) => model.id)).toEqual(["local-opus"]);
});

test("a named local launch profile keeps its own declared models", () => {
  const catalog = mergeModelCatalog(
    { harnesses: [{ id: "claude-internal", family: "claude", models: [{ id: "declared" }] }] },
    { harnesses: [{ harness: "claude-internal", models: [{ id: "probed" }] }] },
  );
  expect(catalog[0]!.models.map((model) => model.id)).toEqual(["declared"]);
});

test("the local harness's reported picker order survives catalog and peer ordering", () => {
  const catalog = mergeModelCatalog(
    { harnesses: [{ id: "claude", name: "Claude Code" }] },
    {
      harnesses: [
        {
          harness: "claude",
          models: [{ id: "fable" }, { id: "opus" }, { id: "old" }],
          topModels: ["opus", "fable"],
        },
        { harness: "claude", peer: "remote", models: [{ id: "remote" }], topModels: ["remote"] },
      ],
    },
  );
  expect(catalog[0]!.topModels).toEqual(["opus", "fable"]);
  expect(catalog[0]!.models.map((model) => model.id)).toEqual(["fable", "opus", "old"]);
});

test("a folded release retains its harness menu position without promoting the running model", async () => {
  const { buildPickerCatalog, BUNDLED_MODEL_CATALOG } = await import("./modelCatalogData");
  const result = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [
      {
        id: "claude",
        name: "Claude Code",
        family: "claude",
        topModels: ["opus", "sonnet"],
        models: [
          { id: "opus", name: "Opus 5.5" },
          { id: "sonnet", name: "Sonnet 5.5" },
          { id: "haiku", name: "Haiku 5.5" },
        ],
      },
    ],
    session: { harness: "claude", model: "claude-haiku-5-5" },
  });
  const harness = result.harnesses.find((entry) => entry.id === "claude")!;
  expect(harness.topModels).toEqual(["opus", "sonnet"]);
  expect(harness.topModels).not.toContain("claude-haiku-5-5");
});

test("a reported Prime family keeps its discovered model or one default entry", async () => {
  const { buildPickerCatalog, BUNDLED_MODEL_CATALOG } = await import("./modelCatalogData");
  const discovered = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [{ id: "prime-agent", name: "Prime Agent", family: "prime", models: [{ id: "prime/x", name: "Prime X" }] }],
  });
  expect(discovered.harnesses.find((entry) => entry.family === "prime")?.models.map((model) => model.id)).toEqual([
    "prime/x",
  ]);

  const fallback = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [
      {
        id: "prime-agent",
        name: "Prime Agent",
        family: "prime",
        models: [{ id: "default", name: "default (agent's choice)" }],
      },
    ],
  });
  expect(fallback.harnesses.find((entry) => entry.family === "prime")?.models.map((model) => model.id)).toEqual([
    "default",
  ]);

  const absent = buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: [] });
  expect(absent.harnesses.some((entry) => entry.family === "prime")).toBe(false);

  const unreportedFamily = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [{ id: "prime-agent", name: "Prime Agent", models: [{ id: "default", name: "default (agent's choice)" }] }],
  });
  expect(unreportedFamily.harnesses.find((entry) => entry.id === "prime-agent")?.family).toBeUndefined();

  const staticOnly = buildPickerCatalog({
    catalog: {
      ...BUNDLED_MODEL_CATALOG,
      harnesses: [
        {
          id: "prime",
          name: "Prime Intellect",
          brand: "prime",
          families: ["prime"],
          modelSource: "probe",
          models: [],
        },
      ],
    },
    acpmux: [],
  });
  expect(staticOnly.harnesses.find((entry) => entry.id === "prime")?.family).toBeUndefined();
});

test("an omitted model effort capability stays distinct from explicit no-effort", async () => {
  const { buildPickerCatalog, BUNDLED_MODEL_CATALOG } = await import("./modelCatalogData");
  const result = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [
      {
        id: "custom-harness",
        name: "Custom",
        family: "custom",
        models: [
          { id: "live-custom", name: "Live custom" },
          { id: "declared-none", name: "Declared none", efforts: [] },
        ],
      },
    ],
    session: {
      harness: "custom-harness",
      model: "live-custom",
      configOptions: [
        {
          id: "thought_level",
          category: "thought_level",
          currentValue: "custom",
          options: [{ value: "custom", name: "Custom" }],
        },
      ],
    },
  });
  const models = result.harnesses.find((entry) => entry.id === "custom-harness")!.models;
  expect(models.find((model) => model.id === "live-custom")?.efforts).toEqual([]);
  expect(models.find((model) => model.id === "live-custom")?.effortsDeclared).toBe(false);
  expect(models.find((model) => model.id === "declared-none")?.efforts).toEqual([]);
  expect(models.find((model) => model.id === "declared-none")?.effortsDeclared).toBe(true);
});

test("a harness acpmux marks pickerHidden (the cmux router fallback) is not a choice", async () => {
  const { buildPickerCatalog, BUNDLED_MODEL_CATALOG } = await import("./modelCatalogData");
  const catalog = mergeModelCatalog(
    {
      harnesses: {
        claude: { family: "claude", kind: "claude-stdio" },
        cmux: { family: "claude", kind: "claude-stdio", pickerHidden: true },
      },
    },
    { harnesses: [{ harness: "cmux", pickerHidden: true, models: [{ id: "deepseek/deepseek-v4-flash" }] }] },
  );
  expect(catalog.filter((entry) => entry.pickable !== false).map((entry) => entry.id)).toEqual(["claude"]);
  // The row stays, with its models, for a chat that already failed over to it.
  expect(catalog.find((entry) => entry.id === "cmux")?.models.map((m) => m.id)).toEqual(["deepseek/deepseek-v4-flash"]);
  const picker = buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: catalog });
  expect(picker.harnesses.filter((entry) => entry.pickable).map((entry) => entry.acpmuxHarness)).not.toContain("cmux");
});
