import { describe, expect, test } from "bun:test";
import { probeClaudeCredential } from "../services/coderouter/claudeCredentialProbe";

type Call = { url: string; init: RequestInit };

function fetchStub(handler: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init: init ?? {} });
    return handler(url, init ?? {});
  }) as typeof fetch;
  return { calls, dependencies: { fetch: fetchImpl, now: () => new Date("2026-09-02T12:00:00.000Z") } };
}

describe("claude credential probe", () => {
  test("an API key is checked with count_tokens and accepted on any non-auth answer", async () => {
    const { calls, dependencies } = fetchStub(() => Response.json({ input_tokens: 3 }));
    const result = await probeClaudeCredential({ kind: "anthropic_api_key", apiKey: "sk-ant-api03-test" }, dependencies);
    expect(result).toEqual({ ok: true, email: null });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://api.anthropic.com/v1/messages/count_tokens");
    const headers = new Headers(calls[0]!.init.headers);
    expect(headers.get("x-api-key")).toBe("sk-ant-api03-test");
    expect(headers.get("authorization")).toBeNull();
    // A 400 (for example an unknown model) still proves the key authenticated.
    const { dependencies: badRequest } = fetchStub(() => Response.json({ type: "error" }, { status: 400 }));
    expect(await probeClaudeCredential({ kind: "anthropic_api_key", apiKey: "sk-ant-api03-test" }, badRequest)).toEqual({ ok: true, email: null });
  });

  test("a rejected key reports the upstream status and message", async () => {
    const { dependencies } = fetchStub(() =>
      Response.json({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }, { status: 401 }));
    expect(await probeClaudeCredential({ kind: "anthropic_api_key", apiKey: "sk-ant-api03-dead" }, dependencies)).toEqual({
      ok: false,
      reason: "rejected",
      status: 401,
      message: "invalid x-api-key",
    });
  });

  test("an OAuth token sends the bearer and beta header and picks up the profile email", async () => {
    const { calls, dependencies } = fetchStub((url) =>
      url.endsWith("/api/oauth/profile")
        ? Response.json({ account: { email: "dev@example.com" } })
        : Response.json({ input_tokens: 3 }));
    const result = await probeClaudeCredential({ kind: "anthropic_oauth", token: "sk-ant-oat01-token" }, dependencies);
    expect(result).toEqual({ ok: true, email: "dev@example.com" });
    const headers = new Headers(calls[0]!.init.headers);
    expect(headers.get("authorization")).toBe("Bearer sk-ant-oat01-token");
    expect(headers.get("anthropic-beta")).toBe("oauth-2025-04-20");
    expect(calls.map((call) => new URL(call.url).pathname)).toEqual(["/v1/messages/count_tokens", "/api/oauth/profile"]);
  });

  test("a failing profile lookup never fails the probe", async () => {
    const { dependencies } = fetchStub((url) =>
      url.endsWith("/api/oauth/profile") ? new Response("nope", { status: 404 }) : Response.json({ input_tokens: 1 }));
    expect(await probeClaudeCredential({ kind: "anthropic_oauth", token: "sk-ant-oat01-token" }, dependencies)).toEqual({ ok: true, email: null });
  });

  test("Bedrock signs the CountTokens call and treats 403 as rejected", async () => {
    const { calls, dependencies } = fetchStub(() => Response.json({ message: "The security token included in the request is invalid." }, { status: 403 }));
    const result = await probeClaudeCredential({
      kind: "bedrock",
      region: "us-west-2",
      accessKeyId: "AKIAIOSFODNN7EXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    }, dependencies);
    expect(result).toMatchObject({ ok: false, reason: "rejected", status: 403 });
    expect(calls[0]!.url).toContain("bedrock-runtime.us-west-2.amazonaws.com");
    expect(calls[0]!.url).toContain("count-tokens");
    expect(new Headers(calls[0]!.init.headers).get("authorization")).toMatch(/^AWS4-HMAC-SHA256 /);
  });

  test("a network failure is unreachable, not rejected", async () => {
    const { dependencies } = fetchStub(() => {
      throw new TypeError("fetch failed");
    });
    expect(await probeClaudeCredential({ kind: "anthropic_api_key", apiKey: "sk-ant-api03-test" }, dependencies)).toEqual({
      ok: false,
      reason: "unreachable",
      message: "fetch failed",
    });
  });
});
