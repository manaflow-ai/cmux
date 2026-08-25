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
          capabilities: ["use", "manage_accounts"],
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
      use: true,
      manageAccounts: true,
    });
    const accounts = await client.listAccounts(tenant.tenantKey);
    await client.deleteTenant("stack-access", "team-1");

    expect(calls[0]?.init.headers).toEqual({
      authorization: "Bearer stack-access",
      "content-type": "application/json",
      "x-subrouter-stack-control-token":
        "0123456789abcdef0123456789abcdef-test",
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

  test("treats a structured already-absent tenant result as successfully deleted", async () => {
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example",
      tenantDeleteToken: "0123456789abcdef0123456789abcdef-test",
      fetch: (async () =>
        Response.json({ ok: true, deleted: false })) as typeof fetch,
    });

    await expect(client.deleteTenant("stack-access", "team-1")).resolves.toBeUndefined();
  });

  test("rejects a hosted tenant credential for a different Stack team", async () => {
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example",
      tenantDeleteToken: "0123456789abcdef0123456789abcdef-test",
      fetch: (async () =>
        Response.json({
          tenantId: "team-other",
          tenantName: "Other",
          tenantKey: "srt_0123456789abcdef0123456789abcdef",
          proxyUrl:
            "https://sr.example/t/srt_0123456789abcdef0123456789abcdef",
          capabilities: ["use"],
        })) as typeof fetch,
    });

    await expect(
      client.exchangeTeam("stack-access", {
        teamId: "team-1",
        teamName: "Acme",
        use: true,
        manageAccounts: false,
      }),
    ).rejects.toMatchObject({ status: 502 });
  });

  test("rejects duplicated hosted tenant capabilities", async () => {
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example",
      tenantDeleteToken: "0123456789abcdef0123456789abcdef-test",
      fetch: (async () =>
        Response.json({
          tenantId: "team-1",
          tenantName: "Acme",
          tenantKey: "srt_0123456789abcdef0123456789abcdef",
          proxyUrl:
            "https://sr.example/t/srt_0123456789abcdef0123456789abcdef",
          capabilities: ["use", "use"],
        })) as typeof fetch,
    });

    await expect(
      client.exchangeTeam("stack-access", {
        teamId: "team-1",
        teamName: "Acme",
        use: true,
        manageAccounts: true,
      }),
    ).rejects.toMatchObject({ status: 502 });
  });

  test("rejects insecure or credential-bearing hosted Subrouter URLs", () => {
    for (const baseUrl of [
      "http://sr.example",
      "https://user:secret@sr.example",
    ]) {
      expect(() =>
        createHostedSubrouterClient({
          baseUrl,
          tenantDeleteToken: "0123456789abcdef0123456789abcdef-test",
        })
      ).toThrow("invalid hosted Subrouter URL");
    }
  });

  test("rejects an unexpected tenant deletion route 404", async () => {
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example",
      tenantDeleteToken: "0123456789abcdef0123456789abcdef-test",
      fetch: (async () =>
        Response.json({ error: "not found" }, { status: 404 })) as typeof fetch,
    });

    await expect(
      client.deleteTenant("stack-access", "team-1"),
    ).rejects.toMatchObject({ status: 404 });
  });

  test("preserves a hosted credential refresh result", async () => {
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example",
      fetch: (async () =>
        Response.json({ ok: true, refreshState: "refreshed" })) as typeof fetch,
    });

    await expect(
      client.reportCredentialLease(
        "srt_0123456789abcdef0123456789abcdef",
        "lease-1",
        { outcome: "unauthorized", statusCode: 401 },
      ),
    ).resolves.toEqual({ ok: true, refreshState: "refreshed" });
  });

  test("rejects unsupported hosted account provider and auth-mode pairs", async () => {
    for (const account of [
      { id: "kimi-account", provider: "kimi", auth_mode: "oauth" },
      { id: "codex-account", provider: "codex", auth_mode: "token" },
    ]) {
      const client = createHostedSubrouterClient({
        baseUrl: "https://sr.example",
        fetch: (async () => Response.json([account])) as typeof fetch,
      });

      await expect(
        client.listAccounts("srt_0123456789abcdef0123456789abcdef"),
      ).rejects.toMatchObject({ status: 502 });
    }
  });
});
