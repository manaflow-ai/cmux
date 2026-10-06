import { describe, expect, test } from "bun:test";

import feed from "./fixtures/model-feed.json";
import snapshot from "../data/model-catalog-snapshot.json";
import { projectCatalog } from "../services/model-catalog/project";
import { createCatalogRoute } from "../services/model-catalog/route";
import type { ModelCatalog } from "../services/model-catalog/types";

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

describe("bundled snapshot", () => {
  test("is a valid catalog marked as snapshot with every harness", () => {
    const catalog = snapshot as ModelCatalog;
    expect(catalog.schemaVersion).toBe(1);
    expect(catalog.source).toBe("snapshot");
    expect(catalog.harnesses.map((entry) => entry.id)).toEqual(["claude", "codex", "opencode", "pi", "vercel-ai-gateway"]);
    expect(harness(catalog, "claude").models.length).toBeGreaterThan(0);
    expect(harness(catalog, "codex").models.length).toBeGreaterThan(0);
  });
});

describe("GET /api/models/catalog", () => {
  function jsonResponse(body: unknown, init: ResponseInit = {}) {
    return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" }, ...init });
  }

  test("serves the projected live feed with CDN caching, CORS and a strong ETag, and answers 304", async () => {
    let fetches = 0;
    const route = createCatalogRoute({
      fetchFeed: async () => {
        fetches += 1;
        return jsonResponse(feed);
      },
      now: () => NOW,
    });
    const response = await route.GET(new Request("https://cmux.test/api/models/catalog"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=300, s-maxage=3600, stale-while-revalidate=86400");
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("x-cmux-catalog-source")).toBe("live");
    const etag = response.headers.get("etag");
    expect(etag).toMatch(/^"[A-Za-z0-9_-]+"$/);
    const body = (await response.json()) as ModelCatalog;
    expect(body.source).toBe("live");
    expect(harness(body, "claude").models[0]?.id).toBe("claude-opus-5-5");

    const revalidated = await route.GET(
      new Request("https://cmux.test/api/models/catalog", { headers: { "if-none-match": etag! } }),
    );
    expect(revalidated.status).toBe(304);
    // The instance keeps the projection for its TTL instead of refetching 5 MB per request.
    expect(fetches).toBe(1);
  });

  test("falls back to the last good projection, then to the bundled snapshot, when the feed fails", async () => {
    let fail = false;
    let clock = NOW.getTime();
    const route = createCatalogRoute({
      fetchFeed: async () => (fail ? new Response("down", { status: 503 }) : jsonResponse(feed)),
      now: () => new Date(clock),
    });
    await route.GET(new Request("https://cmux.test/api/models/catalog"));
    fail = true;
    clock += 2 * 60 * 60 * 1000;
    const stale = await route.GET(new Request("https://cmux.test/api/models/catalog"));
    expect(stale.headers.get("x-cmux-catalog-source")).toBe("live");
    expect(((await stale.json()) as ModelCatalog).source).toBe("live");

    const cold = createCatalogRoute({
      fetchFeed: async () => {
        throw new Error("network down");
      },
      now: () => NOW,
    });
    const fallback = await cold.GET(new Request("https://cmux.test/api/models/catalog"));
    expect(fallback.status).toBe(200);
    expect(fallback.headers.get("x-cmux-catalog-source")).toBe("snapshot");
    // A fallback is cached briefly so the CDN retries the feed soon.
    expect(fallback.headers.get("cache-control")).toBe("public, max-age=60, s-maxage=300, stale-while-revalidate=86400");
    expect(((await fallback.json()) as ModelCatalog).source).toBe("snapshot");
  });

  test("an invalid feed body counts as a failed fetch", async () => {
    const route = createCatalogRoute({ fetchFeed: async () => jsonResponse({ nothing: true }), now: () => NOW });
    const response = await route.GET(new Request("https://cmux.test/api/models/catalog"));
    expect(response.headers.get("x-cmux-catalog-source")).toBe("snapshot");
  });

  test("OPTIONS answers CORS preflight", () => {
    const route = createCatalogRoute({ fetchFeed: async () => jsonResponse(feed), now: () => NOW });
    const response = route.OPTIONS();
    expect(response.status).toBe(204);
    expect(response.headers.get("access-control-allow-methods")).toBe("GET, OPTIONS");
  });
});
