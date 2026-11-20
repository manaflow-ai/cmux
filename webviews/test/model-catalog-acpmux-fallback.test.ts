// l10n-allow-file: test fixtures.
// The page's model catalog when the app does not serve `models.catalog` (the app today): acpmux's
// own copy, read over the pane's direct client (`models.catalog` action -> `catalog.get`), which
// carries the public feed's newer models. A model released today reaches the picker without a page
// or app update (user 2026-11-19: "gemini neon didn't automatically appear in model picker for us").
import { afterEach, beforeEach, expect, test } from "bun:test";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import { NativeError } from "../src/agent-session/acpmux/nativeError";
import {
  loadModelCatalog,
  modelCatalogStateForTests,
  resetModelCatalogForTests,
} from "../src/agent-session/acpmux/modelCatalogHost";
import { BUNDLED_MODEL_CATALOG } from "../src/agent-session/acpmux/modelCatalogData";

const scope = globalThis as { window?: unknown };
/** A stand-in window: the page's i18n follows the window's language events. */
const fakeWindow = (extra: Record<string, unknown> = {}) => ({
  addEventListener() {},
  removeEventListener() {},
  ...extra,
});
const before = scope.window;
const unserved = async () => {
  throw new NativeError({ code: "native.invalid_request", origin: "native" });
};

/** The bundled catalog with one Gemini model the bundle never had, as acpmux's feed adds it. */
function acpmuxCatalog() {
  const catalog = structuredClone(BUNDLED_MODEL_CATALOG) as typeof BUNDLED_MODEL_CATALOG;
  const gemini = catalog.harnesses.find((harness) => harness.id === "gemini")!;
  gemini.models.unshift({ id: "gemini-9-test", ref: "google/gemini-9-test", name: "Gemini 9 Test", shortName: "9 Test" });
  catalog.models["google/gemini-9-test"] = { name: "Gemini 9 Test", releaseDate: "2026-11-19" };
  return catalog;
}

const geminiIds = () =>
  modelCatalogStateForTests().catalog.harnesses.find((harness) => harness.id === "gemini")!.models.map((m) => m.id);

beforeEach(() => resetModelCatalogForTests());
afterEach(() => {
  setNativeHost(undefined);
  scope.window = before;
});

test("a host that does not serve models.catalog gets acpmux's catalog, feed models included", async () => {
  const asked: unknown[] = [];
  setNativeHost(unserved);
  scope.window = fakeWindow({
    cmuxAcpmuxActions: {
      "models.catalog": async (params: unknown) => {
        asked.push(params);
        return { schemaVersion: 1, delivery: "fetched", catalog: acpmuxCatalog() };
      },
    },
  });
  expect(geminiIds()).not.toContain("gemini-9-test");
  await loadModelCatalog(true);
  expect(asked).toEqual([{ refresh: true }]);
  expect(geminiIds()[0]).toBe("gemini-9-test");
  expect(modelCatalogStateForTests().provisional).toBe(false);
});

test("with no acpmux action the bundled catalog stays and the host's refusal is the answer", async () => {
  setNativeHost(unserved);
  scope.window = fakeWindow();
  await expect(loadModelCatalog()).rejects.toBeInstanceOf(NativeError);
  expect(modelCatalogStateForTests().catalog).toBe(BUNDLED_MODEL_CATALOG);
});

test("an acpmux reply without a catalog (an older acpmux) keeps the bundled catalog", async () => {
  setNativeHost(unserved);
  scope.window = fakeWindow({ cmuxAcpmuxActions: { "models.catalog": async () => ({ schemaVersion: 1 }) } });
  await loadModelCatalog();
  expect(modelCatalogStateForTests().catalog).toBe(BUNDLED_MODEL_CATALOG);
  expect(modelCatalogStateForTests().provisional).toBe(true);
});

test("a host that serves models.catalog wins", async () => {
  const served = acpmuxCatalog();
  setNativeHost(async (method) => (method === "models.catalog" ? { catalog: served, delivery: "network" } : undefined));
  scope.window = fakeWindow({ cmuxAcpmuxActions: { "models.catalog": async () => { throw new Error("not asked"); } } });
  await loadModelCatalog();
  expect(geminiIds()[0]).toBe("gemini-9-test");
});

test("a model the catalog disabled never reaches the picker, nor stays the default", async () => {
  const { readModelCatalog } = await import("../src/agent-session/acpmux/modelCatalogData");
  const catalog = acpmuxCatalog();
  const gemini = catalog.harnesses.find((harness) => harness.id === "gemini")!;
  gemini.models[0] = { ...gemini.models[0], status: "disabled" };
  gemini.defaultModel = "gemini-9-test";
  const read = readModelCatalog(catalog)!;
  const after = read.harnesses.find((harness) => harness.id === "gemini")!;
  expect(after.models.map((m) => m.id)).not.toContain("gemini-9-test");
  expect(after.defaultModel).toBeUndefined();
  expect(after.models.length).toBe(gemini.models.length - 1);
});

test("an acpmux that never answers frees the load after its time limit", async () => {
  setNativeHost(unserved);
  scope.window = fakeWindow({ cmuxAcpmuxActions: { "models.catalog": () => new Promise(() => {}) } });
  const realSetTimeout = globalThis.setTimeout;
  globalThis.setTimeout = ((fn: () => void) => realSetTimeout(fn, 0)) as typeof setTimeout;
  try {
    await expect(loadModelCatalog()).rejects.toThrow(/no model catalog from acpmux/);
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
  expect(modelCatalogStateForTests().catalog).toBe(BUNDLED_MODEL_CATALOG);
  // The next load asks again instead of waiting on the stuck one.
  scope.window = fakeWindow({ cmuxAcpmuxActions: { "models.catalog": async () => ({ schemaVersion: 1, catalog: acpmuxCatalog() }) } });
  await loadModelCatalog();
  expect(geminiIds()[0]).toBe("gemini-9-test");
});
