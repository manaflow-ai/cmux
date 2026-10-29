import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import currentFamilies from "../data/model-catalog/current-families.json";
import { withCurrentFamilyFallbacks } from "../services/model-catalog/currentFamilies";
import { validateCatalog } from "../services/model-catalog/schema";
import { BUNDLED_CATALOG_PATH, SNAPSHOT_PATH } from "../tools/model-catalog-paths";

test("both generated fallbacks contain the current family source and retain unknown releases", () => {
  const snapshot = validateCatalog(JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8")));
  expect(readFileSync(BUNDLED_CATALOG_PATH, "utf8")).toBe(readFileSync(SNAPSHOT_PATH, "utf8"));
  expect(withCurrentFamilyFallbacks(snapshot)).toEqual(snapshot);
  for (const [id, families] of Object.entries(currentFamilies)) {
    const harness = snapshot.harnesses.find((entry) => entry.id === id)!;
    expect(harness.models.slice(0, families.length).map((model) => model.id)).toEqual(
      families.map((model) => model.id),
    );
  }
});

test("refreshing identities preserves feed capabilities and defaults without inventing account support", () => {
  const snapshot = validateCatalog(JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8")));
  const codex = snapshot.harnesses.find((entry) => entry.id === "codex")!;
  const original = {
    id: "gpt-6.1-sol",
    name: "Harness Sol",
    shortName: "Harness Sol",
    efforts: ["high" as const],
    fast: false,
  };
  const custom = { id: "future-9", name: "Future 9", shortName: "Future 9" };
  codex.models = [original, custom];
  codex.defaultModel = custom.id;
  const refreshed = withCurrentFamilyFallbacks(snapshot).harnesses.find(
    (entry) => entry.id === "codex",
  )!;
  expect(refreshed.defaultModel).toBe(custom.id);
  expect(refreshed.models.find((model) => model.id === original.id)).toBe(original);
  expect(refreshed.models).toContain(custom);
  const terra = refreshed.models.find((model) => model.id === "gpt-6.1-terra")!;
  expect(terra.efforts).toBeUndefined();
  expect(terra.fast).toBeUndefined();
  expect(codex.models).toEqual([original, custom]);
});

test("changed fallback content advances the revision and unchanged content is stable", () => {
  const snapshot = validateCatalog(JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8")));
  const codex = snapshot.harnesses.find((entry) => entry.id === "codex")!;
  codex.models = codex.models.filter((model) => model.id !== "gpt-6.1-terra");
  const refreshed = withCurrentFamilyFallbacks(snapshot, new Date(snapshot.generatedAt));
  expect(Date.parse(refreshed.generatedAt)).toBeGreaterThan(Date.parse(snapshot.generatedAt));
  expect(withCurrentFamilyFallbacks(refreshed, new Date("2030-01-01"))).toBe(refreshed);
});
