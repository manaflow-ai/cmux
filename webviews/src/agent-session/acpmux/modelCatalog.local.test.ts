import { expect, test } from "bun:test";
import { mergeModelCatalog } from "./modelCatalog";

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
