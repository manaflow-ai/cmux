import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";

import { agentModelCatalog } from "../data/agent-models";

const { GET, OPTIONS, validateAndDeduplicateCatalog } = await import("../app/api/agent-models/route");

describe("agent models route", () => {
  test("serves the checked-in model catalog with cache, CORS, and a strong ETag", async () => {
    const response = await GET(new Request("https://cmux.test/api/agent-models"));
    const payload = JSON.stringify(agentModelCatalog);
    const expectedEtag = `"${createHash("sha256").update(payload).digest("base64url")}"`;

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, s-maxage=300, stale-while-revalidate=86400");
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("access-control-allow-methods")).toBe("GET, OPTIONS");
    expect(response.headers.get("etag")).toBe(expectedEtag);
    expect(await response.json()).toEqual(agentModelCatalog);
  });

  test("serves backend fallbacks for every task-composer provider", () => {
    expect(agentModelCatalog.providers.claude).toMatchObject({
      defaultModel: "claude-sonnet-5",
      models: [
        { id: "claude-fable-5", label: "Claude Fable 5", minVersion: "2.1.169", supportsOneMillion: true },
        { id: "claude-opus-4-8", label: "Claude Opus 4.8", minVersion: "2.1.154", fast: true },
        { id: "claude-opus-4-7", label: "Claude Opus 4.7", minVersion: "2.1.111", fast: true },
        { id: "claude-opus-4-6", label: "Claude Opus 4.6", supportsOneMillion: true, fast: true },
        { id: "claude-opus-4-5", label: "Claude Opus 4.5", fast: true },
        { id: "claude-sonnet-5", label: "Claude Sonnet 5", supportsOneMillion: true },
        { id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", supportsOneMillion: true },
        { id: "claude-haiku-4-5", label: "Claude Haiku 4.5" },
      ],
    });

    expect(agentModelCatalog.providers.gemini).toEqual({
      defaultModel: "gemini-3.1-pro-preview",
      models: [
        { id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro Preview" },
        { id: "gemini-3-pro-preview", label: "Gemini 3 Pro Preview" },
        { id: "gemini-3-flash-preview", label: "Gemini 3 Flash Preview" },
        { id: "gemini-2.5-pro", label: "Gemini 2.5 Pro" },
        { id: "gemini-2.5-flash", label: "Gemini 2.5 Flash" },
        { id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite" },
      ],
    });

    expect(agentModelCatalog.providers.codex.defaultModel).toBe("gpt-5.5");
    expect(agentModelCatalog.providers.codex.models.map((model) => model.id)).toEqual([
      "gpt-5.5",
      "gpt-5.5-pro",
    ]);
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
