import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";

import { agentModelCatalog } from "../data/agent-models";

const { GET, OPTIONS } = await import("../app/api/agent-models/route");

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

  test("preserves current curated Claude, Gemini, and Codex seed models", () => {
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
    expect(agentModelCatalog.providers.codex.models[0].efforts?.map((effort) => effort.value)).toEqual([
      "none",
      "low",
      "medium",
      "high",
      "xhigh",
    ]);
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
});
