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
