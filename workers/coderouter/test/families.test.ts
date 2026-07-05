import { describe, expect, test } from "bun:test";
import { buildUpstreamUrl, injectCredentialHeaders, matchRoute, sanitizeRequestHeaders } from "../src/families";

describe("families", () => {
  test("maps prefixes to upstream paths", () => {
    const anthropic = matchRoute(new URL("https://router.example/anthropic/v1/messages?a=1"));
    expect(anthropic?.endpointClass).toBe("anthropic");
    expect(buildUpstreamUrl(anthropic!, new URL("https://router.example/anthropic/v1/messages?a=1"))).toBe(
      "https://api.anthropic.com/v1/messages?a=1",
    );

    const openai = matchRoute(new URL("https://router.example/openai/v1/responses"));
    expect(openai?.upstreamPath).toBe("/v1/responses");
  });

  test("strips inbound auth and private headers", () => {
    const headers = sanitizeRequestHeaders(
      new Headers({
        authorization: "Bearer crk_secret",
        "x-api-key": "crk_secret",
        "x-coderouter-debug": "1",
        connection: "close",
        "content-type": "application/json",
      }),
    );
    expect(headers.get("authorization")).toBeNull();
    expect(headers.get("x-api-key")).toBeNull();
    expect(headers.get("x-coderouter-debug")).toBeNull();
    expect(headers.get("content-type")).toBe("application/json");
  });

  test("merges and removes oauth beta for anthropic credentials", () => {
    const oauth = injectCredentialHeaders(
      "anthropic",
      "oauth",
      new Headers({ "anthropic-beta": "tools, oauth-2025-04-20", authorization: "Bearer crk" }),
      { authorization: "Bearer access" },
    );
    expect(oauth.get("authorization")).toBe("Bearer access");
    expect(oauth.get("x-api-key")).toBeNull();
    expect(oauth.get("anthropic-beta")).toBe("tools,oauth-2025-04-20");

    const byok = injectCredentialHeaders(
      "anthropic",
      "byok",
      new Headers({ "anthropic-beta": "oauth-2025-04-20,files" }),
      { "x-api-key": "provider-key" },
    );
    expect(byok.get("authorization")).toBeNull();
    expect(byok.get("x-api-key")).toBe("provider-key");
    expect(byok.get("anthropic-beta")).toBe("files");
  });

  test("injects bearer headers for api and account header for codex", () => {
    const api = injectCredentialHeaders("openai_api", "managed", new Headers({ authorization: "Bearer crk" }), {
      authorization: "Bearer provider",
    });
    expect(api.get("authorization")).toBe("Bearer provider");

    const codex = injectCredentialHeaders("codex", "oauth", new Headers({ "chatgpt-account-id": "inbound" }), {
      authorization: "Bearer access",
      "chatgpt-account-id": "acct",
    });
    expect(codex.get("ChatGPT-Account-ID")).toBe("acct");
  });
});
