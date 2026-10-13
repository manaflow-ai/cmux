import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";

import { agentModelsFromCatalog } from "../services/model-catalog/agentModels";
import { bundledSnapshot } from "../services/model-catalog/store";

const { GET, OPTIONS, validateAndDeduplicateCatalog } = await import("../app/api/agent-models/route");
// With no published catalog version (no database here), the route serves the bundled snapshot.
const agentModelCatalog = agentModelsFromCatalog(bundledSnapshot());

describe("agent models route", () => {
  test("serves the model catalog's projection with cache, CORS, and a strong ETag", async () => {
    const response = await GET(new Request("https://cmux.test/api/agent-models"));
    const payload = JSON.stringify(validateAndDeduplicateCatalog(agentModelCatalog));
    const expectedEtag = `"${createHash("sha256").update(payload).digest("base64url")}"`;

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, s-maxage=300, stale-while-revalidate=86400");
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("access-control-allow-methods")).toBe("GET, OPTIONS");
    expect(response.headers.get("etag")).toBe(expectedEtag);
    expect(await response.json()).toEqual(agentModelCatalog);
  });

  test("adds the Claude Code version gates and keeps the OpenCode list", () => {
    const claude = agentModelCatalog.providers.claude.models;
    expect(claude.find((model) => model.id === "claude-fable-5")).toMatchObject({
      label: "Claude Fable 5",
      minVersion: "2.1.169",
      supportsOneMillion: true,
    });
    expect(claude.find((model) => model.id === "claude-opus-4-8")).toMatchObject({ minVersion: "2.1.154", fast: true });

    expect(agentModelCatalog.providers.codex.models.every((model) => !("efforts" in model))).toBe(true);
    expect(agentModelCatalog.providers.opencode).toEqual({
      defaultModel: "anthropic/claude-sonnet-5",
      models: [
        { id: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5" },
        { id: "anthropic/claude-opus-4-8", label: "Claude Opus 4.8" },
        { id: "openai/gpt-5.5", label: "GPT-5.5" },
      ],
    });
  });

  // cx-miuo: the model catalog (services/model-catalog, what /api/models/v1 serves) is the one
  // source of Claude, Codex and Gemini models; agent-chat reads this route, so it must not lag it.
  test("serves every Claude, Codex and Gemini model the model catalog names", async () => {
    const { bundledSnapshot } = await import("../services/model-catalog/store");
    const catalog = bundledSnapshot();
    const response = await GET(new Request("https://cmux.test/api/agent-models"));
    const served = (await response.json()) as {
      providers: Record<string, { defaultModel: string; models: Array<{ id: string; label: string }> }>;
    };
    for (const harness of ["claude", "codex", "gemini"]) {
      const curated = catalog.harnesses.find((entry) => entry.id === harness);
      expect(curated).toBeDefined();
      expect(served.providers[harness].models.map((model) => model.id)).toEqual(
        curated!.models.map((model) => model.id),
      );
    }
    for (const harness of ["claude", "gemini"]) {
      expect(served.providers[harness].defaultModel).toBe(
        catalog.harnesses.find((entry) => entry.id === harness)!.defaultModel!,
      );
    }
    // The 1M context choice is Claude Code's alone; Gemini's 1M window is not a choice.
    expect(served.providers.gemini.models.some((model) => "supportsOneMillion" in model)).toBe(false);
  });

  test("uses the strong ETag for conditional revalidation", async () => {
    const initial = await GET(new Request("https://cmux.test/api/agent-models"));
    const etag = initial.headers.get("etag");
    expect(etag).toBeTruthy();

    const revalidated = await GET(new Request("https://cmux.test/api/agent-models", {
      headers: { "If-None-Match": etag ?? "" },
    }));

    expect(revalidated.status).toBe(304);
    expect(revalidated.headers.get("etag")).toBe(etag);
    expect(await revalidated.text()).toBe("");
  });

  test("answers CORS preflight for public GET access", async () => {
    const response = OPTIONS();

    expect(response.status).toBe(204);
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("access-control-allow-methods")).toBe("GET, OPTIONS");
    expect(response.headers.get("access-control-allow-headers")).toBe("If-None-Match, Content-Type");
  });

  test("validates the schema and deduplicates provider model identifiers", () => {
    const duplicateCatalog = structuredClone(agentModelCatalog) as {
      providers: {
        claude: {
          models: Array<{ id: string; label: string }>;
        };
      };
    };
    duplicateCatalog.providers.claude.models.push({
      id: agentModelCatalog.providers.claude.models[0].id,
      label: "Duplicate must not ship",
    });

    const normalized = validateAndDeduplicateCatalog(duplicateCatalog);
    expect(
      normalized.providers.claude.models.filter(
        (model) => model.id === agentModelCatalog.providers.claude.models[0].id,
      ),
    ).toHaveLength(1);
    expect(normalized.providers.claude.models[0].label).toBe(
      agentModelCatalog.providers.claude.models[0].label,
    );

    expect(() => validateAndDeduplicateCatalog({
      schemaVersion: 2,
      updatedAt: agentModelCatalog.updatedAt,
      providers: agentModelCatalog.providers,
    })).toThrow("schemaVersion");
    expect(() => validateAndDeduplicateCatalog({
      ...agentModelCatalog,
      providers: {
        ...agentModelCatalog.providers,
        claude: {
          defaultModel: "missing-default",
          models: agentModelCatalog.providers.claude.models,
        },
      },
    })).toThrow("defaultModel");
  });
});
