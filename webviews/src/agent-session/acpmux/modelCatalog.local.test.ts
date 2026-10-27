import { expect, test } from "bun:test";
import { mergeModelCatalog } from "./modelCatalog";

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
        { harness: "claude", models: [{ id: "fable" }, { id: "opus" }, { id: "old" }], topModels: ["opus", "fable"] },
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
    acpmux: [{ id: "claude", name: "Claude Code", family: "claude", topModels: ["opus", "sonnet"], models: [
      { id: "opus", name: "Opus 5.5" }, { id: "sonnet", name: "Sonnet 5.5" }, { id: "haiku", name: "Haiku 5.5" },
    ] }],
    session: { harness: "claude", model: "claude-haiku-5-5" },
  });
  const harness = result.harnesses.find((entry) => entry.id === "claude")!;
  expect(harness.topModels).toEqual(["opus", "sonnet"]);
  expect(harness.topModels).not.toContain("claude-haiku-5-5");
});
