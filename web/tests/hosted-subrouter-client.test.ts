import { describe, expect, test } from "bun:test";
import { createHostedSubrouterClient } from "../services/subrouter/hostedClient";

describe("hosted Subrouter client", () => {
  test("exchanges a Stack team and uses the tenant-scoped account API", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      calls.push({ url, init: init ?? {} });
      if (url.endsWith("/_subrouter/auth/stack")) {
        return Response.json({
          tenantId: "team-1",
          tenantName: "Acme",
          tenantKey: "srt_0123456789abcdef0123456789abcdef",
          proxyUrl:
            "https://sr.example/t/srt_0123456789abcdef0123456789abcdef",
        });
      }
      if (url.endsWith("/_subrouter/auth/stack/tenant")) {
        return Response.json({ ok: true, deleted: true });
      }
      return Response.json([
        {
          id: "apikey:openai-apikey:work",
          provider: "codex",
          auth_mode: "apikey",
          email: "apikey:openai-apikey:work",
          health: {
            ok: false,
            message: "refresh failed",
          },
        },
      ]);
    };
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example",
      tenantDeleteToken: "0123456789abcdef0123456789abcdef-test",
      fetch: fetchImpl as typeof fetch,
    });
    const tenant = await client.exchangeTeam("stack-access", {
      teamId: "team-1",
      teamName: "Acme",
    });
    const accounts = await client.listAccounts(tenant.tenantKey);
    await client.deleteTenant("stack-access", "team-1");

    expect(calls[0]?.init.headers).toEqual({
      authorization: "Bearer stack-access",
      "content-type": "application/json",
    });
    expect(calls[1]?.url).toBe(
      "https://sr.example/_subrouter/accounts",
    );
    expect(new Headers(calls[1]?.init.headers).get("authorization")).toBe(
      "Bearer srt_0123456789abcdef0123456789abcdef",
    );
    expect(accounts).toEqual([
      {
        id: "apikey:openai-apikey:work",
        kind: "openai-apikey",
        label: "work",
        health: {
          ok: false,
        },
      },
    ]);
    expect(calls[2]?.url).toBe(
      "https://sr.example/_subrouter/auth/stack/tenant",
    );
    expect(calls[2]?.init.headers).toEqual({
      authorization: "Bearer stack-access",
      "content-type": "application/json",
      "x-subrouter-tenant-delete-token":
        "0123456789abcdef0123456789abcdef-test",
    });
    expect(JSON.parse(String(calls[2]?.init.body))).toEqual({ teamId: "team-1" });
  });
});
