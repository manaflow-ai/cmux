import { describe, expect, test } from "bun:test";
import { GET } from "../app/v1/models/route";
import { isAnthropicRequest } from "../services/coderouter/claudeProxy";

// Both legs reject an unauthenticated request before touching storage, and
// each does so in its own error shape. That shape proves which leg served the
// request without mocking either proxy.

describe("/v1/models dispatch", () => {
  test("serves Anthropic clients from the Claude leg", async () => {
    const response = await GET(
      new Request("https://coderouter.dev/v1/models", {
        headers: { "anthropic-version": "2023-06-01", "x-api-key": "cmux-vm-edge-placeholder" },
      }),
    );
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({
      type: "error",
      error: { type: "authentication_error" },
    });
  });

  test("keeps Codex clients on the OpenAI leg", async () => {
    const response = await GET(
      new Request("https://coderouter.dev/v1/models?client_version=0.146.0"),
    );
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: "unauthorized" });
  });

  test("detects Anthropic clients by the anthropic-version header only", () => {
    expect(isAnthropicRequest(new Request("https://x/v1/models", { headers: { "anthropic-version": "2023-06-01" } }))).toBe(true);
    expect(isAnthropicRequest(new Request("https://x/v1/models", { headers: { "openai-beta": "responses" } }))).toBe(false);
  });
});
