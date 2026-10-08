import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, test } from "bun:test";

import feed from "./fixtures/model-feed.json";
import { projectCatalog } from "../services/model-catalog/project";
import { allowedDocsUrl, MAX_CATALOG_BYTES, validateCatalog } from "../services/model-catalog/schema";
import { LIVE_CACHE_CONTROL, serveModelCatalog, SNAPSHOT_CACHE_CONTROL } from "../services/model-catalog/serve";
import { HARNESS_OVERRIDES } from "../services/model-catalog/overrides";
import { overridesFromRows, seedRows } from "../services/model-catalog/overrideRows";
import { parseOverrideInput } from "../services/model-catalog/admin";
import { ingestFeed, memoryCatalogRepo, publishCatalog } from "../services/model-catalog/publish";
import { bundledSnapshot, CatalogStore, RECHECK_MS } from "../services/model-catalog/store";
import { seedSql } from "../tools/model-catalog-seed-sql";
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

describe("catalog pipeline", () => {
  const seeded = () => memoryCatalogRepo(seedRows());
  const at = (iso: string) => new Date(iso);

  test("a snapshot is stored only when the models.dev content changes", async () => {
    const repo = seeded();
    expect((await ingestFeed(repo, feed, at("2026-10-07T00:00:00Z"))).inserted).toBe(true);
    expect((await ingestFeed(repo, structuredClone(feed), at("2026-10-07T01:00:00Z"))).inserted).toBe(false);
    const changed = structuredClone(feed) as Record<string, { models: Record<string, Record<string, unknown>> }>;
    changed.anthropic!.models["claude-opus-5-5"]!.name = "Claude Opus 5.5 (renamed upstream)";
    expect((await ingestFeed(repo, changed, at("2026-10-07T02:00:00Z"))).inserted).toBe(true);
    expect(repo.snapshots).toHaveLength(2);
    // The stored copy keeps only the providers the overrides read.
    expect(Object.keys(repo.snapshots[0]!.raw as object)).not.toContain("unused");
  });

  test("a version is published only when the served body changes", async () => {
    const repo = seeded();
    expect(await publishCatalog(repo, "cron")).toEqual({ ok: false, error: "no models.dev snapshot yet" });
    await ingestFeed(repo, feed, at("2026-10-07T00:00:00Z"));
    const first = await publishCatalog(repo, "cron");
    expect(first).toMatchObject({ ok: true, published: true });
    expect(await publishCatalog(repo, "cron")).toMatchObject({ ok: true, published: false });
    expect(repo.versions).toHaveLength(1);
    // The seed is overrides.ts: the first version equals the projection of the repo file.
    expect(repo.versions[0]!.catalog).toEqual(JSON.parse(JSON.stringify(projectCatalog(feed, at("2026-10-07T00:00:00Z")))));
  });

  test("an override row hides a model, another renames one, and a publish serves both", async () => {
    const repo = seeded();
    await ingestFeed(repo, feed, at("2026-10-07T00:00:00Z"));
    await publishCatalog(repo, "cron");
    await repo.upsertOverride({ kind: "model", harnessId: "claude", modelId: "claude-opus-4-8", value: { hidden: true }, active: true }, "curator@manaflow.com");
    await repo.upsertOverride({ kind: "model", harnessId: "claude", modelId: "claude-sonnet-5", value: { name: "Sonnet Five" }, active: true }, "curator@manaflow.com");
    const result = await publishCatalog(repo, "curator@manaflow.com");
    expect(result).toMatchObject({ ok: true, published: true });
    const claude = harness(repo.versions.at(-1)!.catalog as ModelCatalog, "claude");
    expect(claude.models.map((model) => model.id)).not.toContain("claude-opus-4-8");
    expect(claude.models.find((model) => model.id === "claude-sonnet-5")?.name).toBe("Sonnet Five");
    // Deactivating the row brings the model back.
    await repo.upsertOverride({ kind: "model", harnessId: "claude", modelId: "claude-opus-4-8", value: { hidden: true }, active: false }, "curator@manaflow.com");
    await publishCatalog(repo, "curator@manaflow.com");
    expect(harness(repo.versions.at(-1)!.catalog as ModelCatalog, "claude").models.map((model) => model.id)).toContain("claude-opus-4-8");
  });

  test("an override that breaks the catalog is refused at publish and the served version stays", async () => {
    const repo = seeded();
    await ingestFeed(repo, feed, at("2026-10-07T00:00:00Z"));
    await publishCatalog(repo, "cron");
    await repo.upsertOverride({ kind: "model", harnessId: "claude", modelId: "claude-sonnet-5", value: { efforts: ["warp"] }, active: true }, "x");
    expect(await publishCatalog(repo, "x")).toMatchObject({ ok: false });
    expect(repo.versions).toHaveLength(1);
  });

  test("the admin input check refuses unknown fields and malformed rows", () => {
    expect(parseOverrideInput({ kind: "model", harnessId: "claude", modelId: "claude-x", value: { hidden: true } })).toMatchObject({ kind: "model" });
    for (const bad of [
      { kind: "model", harnessId: "claude", modelId: "claude-x", value: { command: "rm -rf /" } },
      { kind: "model", harnessId: "claude", value: { hidden: true } },
      { kind: "harness", harnessId: "claude", value: { id: "other", name: "x", brand: "x", families: [], modelSource: "catalog", position: 0 } },
      { kind: "nope", harnessId: "claude", value: {} },
      { kind: "model", harnessId: "claude", modelId: "claude-x", value: {}, active: "yes" },
    ]) {
      expect(parseOverrideInput(bad)).toHaveProperty("error");
    }
  });

  test("the rows round-trip to overrides.ts", () => {
    expect(overridesFromRows(seedRows())).toEqual(JSON.parse(JSON.stringify(HARNESS_OVERRIDES)));
  });

  test("the migration seeds exactly overrides.ts", () => {
    const migration = readFileSync(new URL("../db/migrations/20261007120000_model_catalog/migration.sql", import.meta.url), "utf8");
    expect(migration.endsWith(seedSql())).toBe(true);
  });
});

describe("catalog store", () => {
  const published = async () => {
    const repo = memoryCatalogRepo(seedRows());
    await ingestFeed(repo, feed, NOW);
    await publishCatalog(repo, "cron");
    return repo;
  };

  test("serves the newest published version and rechecks once a minute", async () => {
    const repo = await published();
    let clock = NOW.getTime();
    let reads = 0;
    const counted = { newestVersion: async () => ((reads += 1), repo.newestVersion()) };
    const store = new CatalogStore(counted, bundledSnapshot(), () => clock);
    const built = await store.current();
    expect(built.version).toBe(1);
    expect(built.etag).toBe(`"${repo.versions[0]!.contentHash}"`);
    for (let index = 0; index < 10; index += 1) await store.current();
    expect(reads).toBe(1);
    clock += RECHECK_MS;
    await store.current();
    expect(reads).toBe(2);
  });

  test("with no published version or no database it serves the bundled snapshot, then keeps the last good one", async () => {
    let fail = false;
    const repo = await published();
    let clock = NOW.getTime();
    const empty = new CatalogStore({ newestVersion: async () => undefined }, bundledSnapshot(), () => clock);
    expect((await empty.current()).catalog.source).toBe("snapshot");
    const flaky = new CatalogStore(
      { newestVersion: async () => { if (fail) throw new Error("db down"); return repo.newestVersion(); } },
      bundledSnapshot(),
      () => clock,
    );
    const good = await flaky.current();
    fail = true;
    clock += RECHECK_MS;
    expect((await flaky.current()).etag).toBe(good.etag);
  });
});

describe("GET /api/models/v1", () => {
  const snapshotStore = new CatalogStore({ newestVersion: async () => undefined }, bundledSnapshot(), () => NOW.getTime());

  test("serves one public JSON body with a content-hash ETag and no cookies", async () => {
    const response = await serveModelCatalog(new Request("https://cmux.test/api/models/v1"), snapshotStore);
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

  test("a published version is cached longer, and a matching If-None-Match answers 304", async () => {
    const repo = memoryCatalogRepo(seedRows());
    await ingestFeed(repo, feed, NOW);
    await publishCatalog(repo, "cron");
    const store = new CatalogStore(repo, bundledSnapshot(), () => NOW.getTime());
    const first = await serveModelCatalog(new Request("https://cmux.test/api/models/v1"), store);
    expect(first.headers.get("cache-control")).toBe(LIVE_CACHE_CONTROL);
    expect(first.headers.get("x-cmux-catalog-version")).toBe("1");
    const etag = first.headers.get("etag")!;
    const second = await serveModelCatalog(
      new Request("https://cmux.test/api/models/v1", { headers: { "If-None-Match": `"other", ${etag}` } }),
      store,
    );
    expect(second.status).toBe(304);
    expect(await second.text()).toBe("");
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
