import { afterAll, beforeAll, expect, test } from "bun:test";
import { BUNDLED_MODEL_CATALOG } from "./modelCatalogData";
import { modelCatalogState, receiveModelCatalog, resetModelCatalogForTests } from "./modelCatalogHost";

// A relaunched chat draws its model chip from the host's last catalog, not the bundled one, so the
// chip does not widen when the host answers (ask-66b7d014c3).

const scope = globalThis as Record<string, unknown>;
const had = "localStorage" in scope;
const before = scope.localStorage;

beforeAll(() => {
  const items = new Map<string, string>();
  scope.localStorage = {
    getItem: (key: string) => items.get(key) ?? null,
    setItem: (key: string, value: string) => void items.set(key, value),
    removeItem: (key: string) => void items.delete(key),
  };
});

afterAll(() => {
  resetModelCatalogForTests();
  if (had) scope.localStorage = before;
  else delete scope.localStorage;
});

test("a new page starts on the host's last catalog, still provisional so the host is asked again", () => {
  resetModelCatalogForTests();
  receiveModelCatalog({
    catalog: { ...BUNDLED_MODEL_CATALOG, generatedAt: "2026-11-16T00:00:00Z" },
    user: { overrides: {} },
  });
  resetModelCatalogForTests(true);
  const state = modelCatalogState();
  expect(state.catalog.generatedAt).toBe("2026-11-16T00:00:00Z");
  expect(state.user).toEqual({ overrides: {} });
  expect(state.provisional).toBe(true);
});

test("with nothing remembered, or an unreadable entry, a new page starts on the bundled catalog", () => {
  resetModelCatalogForTests();
  resetModelCatalogForTests(true);
  expect(modelCatalogState().catalog).toBe(BUNDLED_MODEL_CATALOG);
  (scope.localStorage as Storage).setItem("cmux.acpmux.modelCatalog", "{not json");
  resetModelCatalogForTests(true);
  expect(modelCatalogState().catalog).toBe(BUNDLED_MODEL_CATALOG);
});

test("an answer with no catalog keeps the remembered one", () => {
  resetModelCatalogForTests();
  receiveModelCatalog({ catalog: { ...BUNDLED_MODEL_CATALOG, generatedAt: "kept" } });
  receiveModelCatalog({ catalog: null });
  resetModelCatalogForTests(true);
  expect(modelCatalogState().catalog.generatedAt).toBe("kept");
});
