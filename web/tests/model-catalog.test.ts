import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";

import { buildCatalog } from "../services/model-catalog/build";
import { validateOverrides, type CatalogOverrides } from "../services/model-catalog/overrides";
import { CACHE_CONTROL, serveModelCatalog } from "../services/model-catalog/serve";
import { MAX_CATALOG_BYTES, validateCatalog } from "../services/model-catalog/schema";
import {
  bundledSnapshot,
  CatalogStore,
  curatedOverrides,
  FAILURE_BACKOFF_MS,
  MEMORY_RECHECK_MS,
  REFRESH_AFTER_MS,
  type CatalogStoreDeps,
} from "../services/model-catalog/store";
import { fetchUpstream, selectUpstream, type UpstreamSubset } from "../services/model-catalog/upstream";

const T0 = Date.parse("2026-10-07T00:00:00.000Z");

function modelsDev(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    anthropic: {
      id: "anthropic",
      name: "Anthropic",
      models: {
        "claude-opus-5": {
          id: "claude-opus-5",
          name: "Claude Opus 5",
          family: "claude-opus",
          release_date: "2026-07-24",
          last_updated: "2026-07-24",
          tool_call: true,
          modalities: { input: ["text", "image"], output: ["text"] },
          limit: { context: 1_000_000, output: 128_000 },
          cost: { input: 5, output: 25, cache_read: 0.5 },
        },
        "claude-sonnet-5": {
          id: "claude-sonnet-5",
          name: "Claude Sonnet 5",
          release_date: "2026-06-29",
          tool_call: true,
          limit: { context: 1_000_000, output: 64_000 },
        },
        "claude-old": { id: "claude-old", name: "Claude Old", status: "deprecated", tool_call: true },
        ...overrides,
      },
    },
    unrelated: { id: "unrelated", name: "Unrelated", models: { x: { id: "x", name: "X" } } },
  };
}

function overrides(models: Record<string, unknown> = {}, rule: unknown = "*"): CatalogOverrides {
  return validateOverrides({
    version: 1,
    updatedAt: "2026-10-01T00:00:00.000Z",
    harnesses: [
      {
        id: "claude",
        name: "Claude Code",
        icon: "claude",
        modelIds: "bare",
        providers: [{ id: "anthropic", models: rule }],
        models,
      },
    ],
  });
}

const subset = (document: unknown, fetchedAt = "2026-10-07T00:00:00.000Z") =>
  selectUpstream(document, ["anthropic"], fetchedAt);
const ids = (catalog: ReturnType<typeof buildCatalog>) => catalog.harnesses[0]!.models.map((model) => model.id);

describe("model catalog merge", () => {
  test("takes the curated providers only and hides deprecated models by default", () => {
    const catalog = buildCatalog(subset(modelsDev()), overrides());
    expect(ids(catalog)).toEqual(["claude-opus-5", "claude-sonnet-5"]);
    expect(catalog.harnesses[0]!.models[0]).toMatchObject({
      name: "Claude Opus 5",
      provider: "anthropic",
      providerName: "Anthropic",
      contextWindow: 1_000_000,
      cost: { input: 5, output: 25, cacheRead: 0.5 },
    });
    expect(catalog.updatedAt).toBe("2026-10-01T00:00:00.000Z");
  });

  test("an override hides a model", () => {
    const catalog = buildCatalog(subset(modelsDev()), overrides({ "anthropic/claude-sonnet-5": { hidden: true } }));
    expect(ids(catalog)).toEqual(["claude-opus-5"]);
  });

  test("an override renames a model and corrects its fields", () => {
    const catalog = buildCatalog(
      subset(modelsDev()),
      overrides({
        "anthropic/claude-opus-5": { name: "Opus 5", default: true, recommended: true, contextWindow: 200_000, cost: { input: 1, output: 2 } },
        "anthropic/claude-old": { hidden: false },
      }),
    );
    const harness = catalog.harnesses[0]!;
    expect(harness.defaultModel).toBe("claude-opus-5");
    expect(harness.models[0]).toMatchObject({ name: "Opus 5", default: true, recommended: true, contextWindow: 200_000, cost: { input: 1, output: 2 } });
    expect(ids(catalog)).toContain("claude-old");
  });

  test("an override adds a model models.dev does not list, and an explicit list keeps its order", () => {
    const catalog = buildCatalog(
      subset(modelsDev()),
      overrides({ "anthropic/opus": { name: "Opus (latest)" } }, ["opus", "claude-sonnet-5", "claude-missing", "claude-opus-5"]),
    );
    // A listed id that neither models.dev nor the overrides name is left out.
    expect(ids(catalog)).toEqual(["opus", "claude-sonnet-5", "claude-opus-5"]);
  });

  test("a models.dev field change does not break the schema", () => {
    const changed = modelsDev({
      "claude-opus-5": {
        id: "claude-opus-5",
        name: "Claude Opus 5",
        tool_call: "yes",
        limit: { context: "1M" },
        cost: { input: "five", output: 25 },
        modalities: { input: ["text", "hologram"], output: "text" },
        release_date: "July 2026",
        brand_new_field: { nested: true },
      },
      "no-name": { id: "no-name" },
      "bad id with spaces": { id: "bad id with spaces", name: "Bad" },
      "not-an-object": 42,
    });
    const catalog = buildCatalog(subset(changed), overrides());
    expect(() => validateCatalog(JSON.parse(JSON.stringify(catalog)))).not.toThrow();
    const opus = catalog.harnesses[0]!.models.find((model) => model.id === "claude-opus-5")!;
    expect(opus).toEqual({ id: "claude-opus-5", name: "Claude Opus 5", provider: "anthropic", providerName: "Anthropic" });
    expect(ids(catalog)).toContain("no-name");
    expect(ids(catalog)).not.toContain("bad id with spaces");
  });

  test("a document without the curated providers is an upstream failure", () => {
    expect(() => subset({ other: { models: {} } })).toThrow();
    expect(() => subset([1, 2, 3])).toThrow();
  });

  test("two default models refuse the build", () => {
    expect(() =>
      buildCatalog(
        subset(modelsDev()),
        overrides({ "anthropic/claude-opus-5": { default: true }, "anthropic/claude-sonnet-5": { default: true } }),
      ),
    ).toThrow();
  });

  test("the overrides file is strict", () => {
    const base = { version: 1, updatedAt: "2026-10-01T00:00:00.000Z" };
    const harness = { id: "claude", name: "Claude", modelIds: "bare", providers: [{ id: "anthropic", models: "*" }] };
    expect(() => validateOverrides({ ...base, harnesses: [{ ...harness, command: "rm -rf /" }] })).toThrow();
    expect(() => validateOverrides({ ...base, harnesses: [{ ...harness, docsUrl: "https://evil.example/docs" }] })).toThrow();
    expect(() => validateOverrides({ ...base, harnesses: [{ ...harness, docsUrl: "http://docs.claude.com/" }] })).toThrow();
    expect(() => validateOverrides({ ...base, harnesses: [{ ...harness, models: { "openai/gpt": {} } }] })).toThrow();
    expect(() => validateOverrides({ ...base, version: 2, harnesses: [harness] })).toThrow();
  });
});

describe("the checked-in catalog", () => {
  test("the curated overrides build from the bundled snapshot, well under the size limit", () => {
    const catalog = buildCatalog(bundledSnapshot(), curatedOverrides);
    const bytes = Buffer.byteLength(JSON.stringify(catalog));
    expect(bytes).toBeLessThan(MAX_CATALOG_BYTES);
    expect(MAX_CATALOG_BYTES).toBeLessThan(2 * 1024 * 1024);
    expect(catalog.harnesses.map((harness) => harness.id)).toEqual(["claude", "codex", "gemini", "opencode", "pi", "aider"]);
    for (const harness of catalog.harnesses.filter((entry) => entry.id !== "aider")) {
      expect(harness.models.length).toBeGreaterThan(0);
    }
  });
});

function deps(overridesValue: CatalogOverrides, snapshot: UpstreamSubset, clock: { now: number }) {
  const shared: { value?: unknown; writes: number } = { writes: 0 };
  const calls = { fetches: 0 };
  let next: () => Promise<UpstreamSubset> = async () => {
    throw new Error("models.dev is down");
  };
  const value: CatalogStoreDeps = {
    overrides: overridesValue,
    snapshot,
    readShared: async () => shared.value,
    writeShared: async (subsetValue) => {
      shared.writes += 1;
      shared.value = JSON.parse(JSON.stringify(subsetValue));
    },
    fetchUpstream: async () => {
      calls.fetches += 1;
      return next();
    },
    now: () => clock.now,
  };
  return { value, shared, calls, setNext: (fn: () => Promise<UpstreamSubset>) => (next = fn) };
}

describe("catalog store", () => {
  const snapshot = subset(modelsDev(), "2026-09-01T00:00:00.000Z");
  const tasks: Promise<unknown>[] = [];
  const defer = (task: Promise<unknown>) => void tasks.push(task);
  const settle = async () => {
    await Promise.all(tasks.splice(0));
  };

  test("serves the snapshot first, then the refreshed copy, without a request waiting for models.dev", async () => {
    const clock = { now: T0 };
    const harness = deps(overrides(), snapshot, clock);
    const store = new CatalogStore(harness.value);
    harness.setNext(async () => subset(modelsDev({ "claude-new": { id: "claude-new", name: "Claude New", tool_call: true } }), new Date(clock.now).toISOString()));
    const first = await store.current(defer);
    expect(first.source).toBe("snapshot");
    await settle();
    expect(harness.calls.fetches).toBe(1);
    expect(harness.shared.writes).toBe(1);
    const second = await store.current(defer);
    expect(second.source).toBe("live");
    expect(second.catalog.harnesses[0]!.models.map((model) => model.id)).toContain("claude-new");
    // A fresh copy is not refetched on later requests.
    for (let index = 0; index < 20; index += 1) await store.current(defer);
    await settle();
    expect(harness.calls.fetches).toBe(1);
  });

  test("a models.dev outage serves the last good build and backs off", async () => {
    const clock = { now: T0 };
    const harness = deps(overrides(), snapshot, clock);
    const store = new CatalogStore(harness.value);
    harness.setNext(async () => subset(modelsDev(), new Date(clock.now).toISOString()));
    await store.current(defer);
    await settle();
    const good = await store.current(defer);
    expect(good.source).toBe("live");

    harness.setNext(async () => {
      throw new Error("models.dev is down");
    });
    clock.now += REFRESH_AFTER_MS + 1;
    const during = await store.current(defer);
    await settle();
    expect(during.etag).toBe(good.etag);
    expect(harness.calls.fetches).toBe(2);
    // The failed refresh does not retry on every request.
    for (let index = 0; index < 10; index += 1) await store.current(defer);
    await settle();
    expect(harness.calls.fetches).toBe(2);
    clock.now += FAILURE_BACKOFF_MS + 1;
    const after = await store.current(defer);
    await settle();
    expect(harness.calls.fetches).toBe(3);
    expect(after.etag).toBe(good.etag);
  });

  test("a fetched copy that does not build is not kept or stored", async () => {
    const clock = { now: T0 };
    const twoDefaults = overrides({ "anthropic/claude-new": { default: true }, "anthropic/claude-opus-5": { default: true } });
    const harness = deps(twoDefaults, subset(modelsDev(), "2026-09-01T00:00:00.000Z"), clock);
    const store = new CatalogStore(harness.value);
    harness.setNext(async () => subset(modelsDev({ "claude-new": { id: "claude-new", name: "New", tool_call: true } })));
    expect((await store.current(defer)).source).toBe("snapshot");
    await settle();
    expect(harness.shared.writes).toBe(0);
    expect((await store.current(defer)).source).toBe("snapshot");
  });

  test("a new instance uses the shared copy another instance stored", async () => {
    const clock = { now: T0 };
    const harness = deps(overrides(), snapshot, clock);
    harness.shared.value = JSON.parse(JSON.stringify(subset(modelsDev(), new Date(T0).toISOString())));
    const store = new CatalogStore(harness.value);
    const built = await store.current(defer);
    await settle();
    expect(built.source).toBe("live");
    expect(harness.calls.fetches).toBe(0);
    // A corrupt shared entry falls back to memory, not to an error.
    harness.shared.value = { fetchedAt: "nope", providers: 5 };
    clock.now += MEMORY_RECHECK_MS + 1;
    expect((await store.current(defer)).etag).toBe(built.etag);
  });
});

describe("GET /api/models/v1", () => {
  const store = new CatalogStore({
    overrides: curatedOverrides,
    snapshot: bundledSnapshot(),
    readShared: async () => undefined,
    writeShared: async () => undefined,
    fetchUpstream: async () => {
      throw new Error("offline");
    },
    now: () => T0,
  });
  const ignore = () => undefined;

  test("serves one public JSON body with a content-hash ETag and no cookies", async () => {
    const response = await serveModelCatalog(new Request("https://cmux.test/api/models/v1"), store, ignore);
    const body = await response.text();
    expect(response.status).toBe(200);
    expect(response.headers.get("etag")).toBe(`"${createHash("sha256").update(body).digest("base64url")}"`);
    expect(response.headers.get("cache-control")).toBe(CACHE_CONTROL);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(Buffer.byteLength(body)).toBeLessThan(2 * 1024 * 1024);
    expect(JSON.parse(body).version).toBe(1);
  });

  test("answers 304 on a matching If-None-Match", async () => {
    const first = await serveModelCatalog(new Request("https://cmux.test/api/models/v1"), store, ignore);
    const etag = first.headers.get("etag")!;
    const second = await serveModelCatalog(
      new Request("https://cmux.test/api/models/v1", { headers: { "If-None-Match": `"other", ${etag}` } }),
      store,
      ignore,
    );
    expect(second.status).toBe(304);
    expect(await second.text()).toBe("");
    expect(second.headers.get("etag")).toBe(etag);
  });
});

describe("models.dev fetch", () => {
  test("refuses an oversize body", async () => {
    const huge = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array(8 * 1024 * 1024));
      },
    });
    await expect(fetchUpstream(["anthropic"], { fetch: async () => new Response(huge, { status: 200 }) })).rejects.toThrow(/above/);
  });

  test("refuses an error status", async () => {
    await expect(fetchUpstream(["anthropic"], { fetch: async () => new Response("down", { status: 503 }) })).rejects.toThrow(/503/);
  });

  test("reads the curated providers from a good body", async () => {
    const result = await fetchUpstream(["anthropic"], {
      fetch: async () => Response.json(modelsDev()),
      now: () => new Date(T0),
    });
    expect(Object.keys(result.providers)).toEqual(["anthropic"]);
    expect(result.fetchedAt).toBe(new Date(T0).toISOString());
  });
});
