import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, test } from "bun:test";

import feed from "./fixtures/model-feed.json";
import { projectCatalog } from "../services/model-catalog/project";
import { allowedDocsUrl, MAX_CATALOG_BYTES, validateCatalog } from "../services/model-catalog/schema";
import { LIVE_CACHE_CONTROL, serveModelCatalog, SNAPSHOT_CACHE_CONTROL } from "../services/model-catalog/serve";
import {
  bundledSnapshot,
  CatalogStore,
  FAILURE_BACKOFF_MS,
  MEMORY_RECHECK_MS,
  REFRESH_AFTER_MS,
  type CatalogStoreDeps,
} from "../services/model-catalog/store";
import type { ModelCatalog } from "../services/model-catalog/types";
import { fetchFeed } from "../services/model-catalog/upstream";
import { BUNDLED_CATALOG_PATH, SNAPSHOT_PATH } from "../tools/model-catalog-paths";

const NOW = new Date("2026-10-06T18:00:00.000Z");

function harness(catalog: ModelCatalog, id: string) {
  const entry = catalog.harnesses.find((candidate) => candidate.id === id);
  if (!entry) throw new Error(`missing harness ${id}`);
  return entry;
}

describe("projectCatalog", () => {
  const catalog = projectCatalog(feed, NOW);

  test("lists the five composer harnesses in order with names and brand marks", () => {
    expect(catalog.harnesses.map((entry) => [entry.id, entry.name, entry.brand, entry.modelSource])).toEqual([
      ["claude", "Claude Code", "claude", "catalog"],
      ["codex", "Codex", "openai", "catalog"],
      ["opencode", "OpenCode", "opencode", "probe"],
      ["pi", "Pi", "pi", "probe"],
      ["vercel-ai-gateway", "Vercel AI Gateway", "vercel", "catalog"],
    ]);
    expect(catalog).toMatchObject({ schemaVersion: 1, generatedAt: NOW.toISOString(), source: "live" });
  });

  test("Claude Code gets feed models with cleaned names, family groups, efforts, fast mode and aliases", () => {
    const claude = harness(catalog, "claude");
    // Dated snapshots duplicate their alias; newest family member first inside each family.
    expect(claude.models.map((model) => model.id)).toEqual([
      "claude-opus-5-5",
      "claude-opus-4-8",
      "claude-sonnet-5",
      "claude-haiku-4-5",
    ]);
    expect(claude.models[0]).toEqual({
      id: "claude-opus-5-5",
      ref: "anthropic/claude-opus-5-5",
      name: "Claude Opus 5.5",
      shortName: "Opus 5.5",
      family: "Opus",
      provider: "anthropic",
      efforts: ["low", "medium", "high", "xhigh", "max"],
      fast: true,
      aliases: ["opus"],
    });
    // "(latest)" is feed bookkeeping, not part of the name; budget-only reasoning has no effort list.
    expect(claude.models[3]).toMatchObject({ name: "Claude Haiku 4.5", shortName: "Haiku 4.5", aliases: ["haiku"] });
    expect(claude.models[3]?.efforts).toBeUndefined();
    expect(claude.models[3]?.fast).toBeUndefined();
    expect(claude.defaultModel).toBe("claude-sonnet-5");
  });

  test("Codex drops API-only efforts, applies its default effort and filters chat and pro variants", () => {
    const codex = harness(catalog, "codex");
    expect(codex.models.map((model) => model.id)).toEqual(["gpt-6.1-sol", "gpt-5.5"]);
    expect(codex.models[1]).toMatchObject({
      name: "GPT-5.5",
      shortName: "GPT-5.5",
      efforts: ["low", "medium", "high", "xhigh"],
      defaultEffort: "medium",
      fast: true,
    });
    expect(codex.defaultModel).toBe("gpt-5.5");
  });

  test("probe harnesses carry no list; their models are described by ref", () => {
    expect(harness(catalog, "opencode").models).toEqual([]);
    expect(catalog.models["opencode/big-pickle"]?.name).toBeString();
    expect(catalog.models["anthropic/claude-opus-4-8"]).toMatchObject({
      name: "Claude Opus 4.8",
      contextWindow: 1000000,
      reasoning: true,
      toolCall: true,
    });
    expect(catalog.models["unused/x"]).toBeUndefined();
    expect(catalog.providers.anthropic).toEqual({ name: "Anthropic" });
  });

  test("the AI Gateway lists gateway ids grouped by provider, only for included providers", () => {
    const gateway = harness(catalog, "vercel-ai-gateway");
    expect(gateway.models.map((model) => [model.id, model.ref, model.family, model.provider])).toEqual([
      ["anthropic/claude-sonnet-5", "vercel/anthropic/claude-sonnet-5", "Anthropic", "anthropic"],
      ["openai/gpt-5.5", "vercel/openai/gpt-5.5", "OpenAI", "openai"],
    ]);
  });

  test("a default model the feed lacks falls back to the first listed model", () => {
    const withoutSonnet = structuredClone(feed) as typeof feed;
    delete (withoutSonnet.anthropic.models as Record<string, unknown>)["claude-sonnet-5"];
    expect(harness(projectCatalog(withoutSonnet, NOW), "claude").defaultModel).toBe("claude-opus-5-5");
  });

  test("malformed feed models are skipped, not fatal", () => {
    const broken = structuredClone(feed) as Record<string, { models: Record<string, unknown> }>;
    broken.anthropic!.models["claude-opus-9"] = { id: 7, name: null };
    broken.anthropic!.models["claude-opus-4-8"] = "not a model";
    const ids = harness(projectCatalog(broken, NOW), "claude").models.map((model) => model.id);
    expect(ids).toEqual(["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5"]);
  });

  test("a feed with no Claude or Codex models is refused", () => {
    expect(() => projectCatalog({ anthropic: { id: "anthropic", name: "Anthropic", models: {} } }, NOW)).toThrow();
    expect(() => projectCatalog("nope", NOW)).toThrow();
  });
});

describe("overrides", () => {
  const catalog = projectCatalog(feed, NOW);

  test("an override hides a model and renames another", async () => {
    const { HARNESS_OVERRIDES } = await import("../services/model-catalog/overrides");
    const overrides = structuredClone(HARNESS_OVERRIDES);
    const claude = overrides.find((entry) => entry.id === "claude")!;
    claude.models = { "claude-opus-4-8": { hidden: true }, "claude-sonnet-5": { name: "Sonnet Five", shortName: "S5" } };
    const changed = harness(projectCatalog(feed, NOW, overrides), "claude");
    expect(changed.models.map((model) => model.id)).not.toContain("claude-opus-4-8");
    expect(changed.models.find((model) => model.id === "claude-sonnet-5")).toMatchObject({ name: "Sonnet Five", shortName: "S5" });
    expect(harness(catalog, "claude").models.map((model) => model.id)).toContain("claude-opus-4-8");
  });

  test("a models.dev field change does not break the schema", () => {
    const changed = structuredClone(feed) as Record<string, { models: Record<string, Record<string, unknown>> }>;
    const opus = changed.anthropic!.models["claude-opus-5-5"]!;
    opus.limit = { context: "1M", output: -4 };
    opus.cost = { input: "five", output: 25 };
    opus.modalities = { input: ["text", "hologram"], output: "text" };
    opus.reasoning_options = "lots";
    opus.brand_new_field = { nested: true };
    const projected = projectCatalog(changed, NOW);
    expect(() => validateCatalog(JSON.parse(JSON.stringify(projected)))).not.toThrow();
    expect(projected.models["anthropic/claude-opus-5-5"]).toMatchObject({ name: "Claude Opus 5.5", input: ["text"], cost: { output: 25 } });
    expect(projected.models["anthropic/claude-opus-5-5"]?.contextWindow).toBeUndefined();
  });

  test("every harness docs URL is on the allowlist", () => {
    for (const entry of catalog.harnesses) {
      if (entry.docsUrl) expect(allowedDocsUrl(entry.docsUrl)).toBe(true);
    }
    expect(allowedDocsUrl("https://evil.example/x")).toBe(false);
    expect(allowedDocsUrl("http://github.com/x")).toBe(false);
  });
});

describe("validateCatalog", () => {
  const good = () => JSON.parse(JSON.stringify(projectCatalog(feed, NOW))) as Record<string, unknown> & ModelCatalog;

  test("accepts a projection and refuses a broken one", () => {
    expect(() => validateCatalog(good())).not.toThrow();
    const cases: ((catalog: ReturnType<typeof good>) => void)[] = [
      (c) => void ((c as Record<string, unknown>).schemaVersion = 2),
      (c) => void ((c as Record<string, unknown>).harnesses = []),
      (c) => void (c.harnesses[0]!.models[0]!.efforts = ["warp-speed" as never]),
      (c) => void (c.harnesses[0]!.defaultModel = "nope"),
      (c) => void (c.harnesses[0]!.docsUrl = "https://evil.example/install.sh"),
      (c) => void c.harnesses[0]!.models.push(c.harnesses[0]!.models[0]!),
      (c) => void ((c.models as Record<string, unknown>)["anthropic/x"] = { name: 5 }),
    ];
    for (const breakIt of cases) {
      const catalog = good();
      breakIt(catalog);
      expect(() => validateCatalog(catalog)).toThrow();
    }
  });
});

describe("the checked-in catalog", () => {
  test("the snapshot is valid, every harness is present, and it is well under the size limit", () => {
    const catalog = bundledSnapshot();
    expect(catalog.source).toBe("snapshot");
    expect(catalog.harnesses.map((entry) => entry.id)).toEqual(["claude", "codex", "opencode", "pi", "vercel-ai-gateway"]);
    expect(harness(catalog, "claude").models.length).toBeGreaterThan(0);
    expect(Buffer.byteLength(JSON.stringify(catalog))).toBeLessThan(MAX_CATALOG_BYTES);
    expect(MAX_CATALOG_BYTES).toBeLessThan(2 * 1024 * 1024);
  });

  test("acpmux bundles the same catalog", () => {
    // Regenerate both with: bun tools/refresh-model-catalog-snapshot.ts
    expect(readFileSync(BUNDLED_CATALOG_PATH, "utf8")).toBe(readFileSync(SNAPSHOT_PATH, "utf8"));
  });
});

function deps(clock: { now: number }) {
  const shared: { value?: unknown; writes: number } = { writes: 0 };
  const calls = { fetches: 0 };
  let next: (now: Date) => Promise<ModelCatalog> = async () => {
    throw new Error("models.dev is down");
  };
  const value: CatalogStoreDeps = {
    snapshot: bundledSnapshot(),
    readShared: async () => shared.value,
    writeShared: async (catalog) => {
      shared.writes += 1;
      shared.value = JSON.parse(JSON.stringify(catalog));
    },
    loadLive: async (now) => {
      calls.fetches += 1;
      return next(now);
    },
    now: () => clock.now,
  };
  return { value, shared, calls, setNext: (fn: (now: Date) => Promise<ModelCatalog>) => (next = fn) };
}

describe("catalog store", () => {
  const tasks: Promise<unknown>[] = [];
  const defer = (task: Promise<unknown>) => void tasks.push(task);
  const settle = async () => {
    await Promise.all(tasks.splice(0));
  };
  const live = async (now: Date) => projectCatalog(feed, now);

  test("serves the snapshot first, then the refreshed copy, without a request waiting for models.dev", async () => {
    const clock = { now: NOW.getTime() };
    const harnessDeps = deps(clock);
    const store = new CatalogStore(harnessDeps.value);
    harnessDeps.setNext(live);
    expect((await store.current(defer)).catalog.source).toBe("snapshot");
    await settle();
    expect(harnessDeps.calls.fetches).toBe(1);
    expect(harnessDeps.shared.writes).toBe(1);
    expect((await store.current(defer)).catalog.source).toBe("live");
    for (let index = 0; index < 20; index += 1) await store.current(defer);
    await settle();
    expect(harnessDeps.calls.fetches).toBe(1);
  });

  test("a models.dev outage serves the last good build and backs off", async () => {
    const clock = { now: NOW.getTime() };
    const harnessDeps = deps(clock);
    const store = new CatalogStore(harnessDeps.value);
    harnessDeps.setNext(live);
    await store.current(defer);
    await settle();
    const good = await store.current(defer);
    expect(good.catalog.source).toBe("live");
    harnessDeps.setNext(async () => {
      throw new Error("models.dev is down");
    });
    clock.now += REFRESH_AFTER_MS + 1;
    const during = await store.current(defer);
    await settle();
    expect(during.etag).toBe(good.etag);
    expect(harnessDeps.calls.fetches).toBe(2);
    for (let index = 0; index < 10; index += 1) await store.current(defer);
    await settle();
    expect(harnessDeps.calls.fetches).toBe(2);
    clock.now += FAILURE_BACKOFF_MS + 1;
    expect((await store.current(defer)).etag).toBe(good.etag);
    await settle();
    expect(harnessDeps.calls.fetches).toBe(3);
  });

  test("a projection that does not validate is not kept or stored", async () => {
    const clock = { now: NOW.getTime() };
    const harnessDeps = deps(clock);
    const store = new CatalogStore(harnessDeps.value);
    harnessDeps.setNext(async (now) => ({ ...projectCatalog(feed, now), harnesses: [] }));
    await store.current(defer);
    await settle();
    expect(harnessDeps.shared.writes).toBe(0);
    expect((await store.current(defer)).catalog.source).toBe("snapshot");
  });

  test("a new instance uses the shared copy another instance stored", async () => {
    const clock = { now: NOW.getTime() };
    const harnessDeps = deps(clock);
    harnessDeps.shared.value = JSON.parse(JSON.stringify(projectCatalog(feed, NOW)));
    const store = new CatalogStore(harnessDeps.value);
    const built = await store.current(defer);
    await settle();
    expect(built.catalog.source).toBe("live");
    expect(harnessDeps.calls.fetches).toBe(0);
    harnessDeps.shared.value = { schemaVersion: 1, harnesses: 5 };
    clock.now += MEMORY_RECHECK_MS + 1;
    expect((await store.current(defer)).etag).toBe(built.etag);
  });
});

describe("GET /api/models/v1", () => {
  const ignore = () => undefined;
  const offline = (shared?: unknown) =>
    new CatalogStore({
      snapshot: bundledSnapshot(),
      readShared: async () => shared,
      writeShared: async () => undefined,
      loadLive: async () => {
        throw new Error("offline");
      },
      now: () => NOW.getTime(),
    });

  test("serves one public JSON body with a content-hash ETag and no cookies", async () => {
    const response = await serveModelCatalog(new Request("https://cmux.test/api/models/v1"), offline(), ignore);
    const body = await response.text();
    expect(response.status).toBe(200);
    expect(response.headers.get("etag")).toBe(`"${createHash("sha256").update(body).digest("base64url")}"`);
    expect(response.headers.get("cache-control")).toBe(SNAPSHOT_CACHE_CONTROL);
    expect(response.headers.get("x-cmux-catalog-source")).toBe("snapshot");
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(Buffer.byteLength(body)).toBeLessThan(2 * 1024 * 1024);
    expect(JSON.parse(body).schemaVersion).toBe(1);
  });

  test("a live copy is cached longer, and a matching If-None-Match answers 304", async () => {
    const store = offline(JSON.parse(JSON.stringify(projectCatalog(feed, NOW))));
    const first = await serveModelCatalog(new Request("https://cmux.test/api/models/v1"), store, ignore);
    expect(first.headers.get("cache-control")).toBe(LIVE_CACHE_CONTROL);
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
    await expect(fetchFeed({ fetch: async () => new Response(huge, { status: 200 }) })).rejects.toThrow(/above/);
  });

  test("refuses an error status", async () => {
    await expect(fetchFeed({ fetch: async () => new Response("down", { status: 503 }) })).rejects.toThrow(/503/);
  });
});
