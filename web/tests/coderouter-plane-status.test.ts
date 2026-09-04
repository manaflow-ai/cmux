import { describe, expect, test } from "bun:test";
import { createPlaneStatusHandler, planeStatusForAccounts } from "../services/coderouter/planeStatus";
import type { CodeRouterAccountSummary } from "../services/coderouter/types";

// A machine asks its plane which agents will work right now. The answer is
// route-token scoped and carries counts and kinds only — never an account
// identifier, label, or credential.

function account(
  provider: CodeRouterAccountSummary["provider"],
  overrides: Partial<CodeRouterAccountSummary> = {},
): CodeRouterAccountSummary {
  return {
    id: `id-${provider}`,
    provider,
    providerAccountId: `acct-${provider}`,
    label: "person@example.com",
    state: "active",
    credentialExpiresAt: null,
    lastFailureCode: null,
    cooldownUntil: null,
    activeSessions: 0,
    ...overrides,
  };
}

describe("planeStatusForAccounts", () => {
  test("no accounts: nothing is ready and every agent names its fix", () => {
    const status = planeStatusForAccounts([]);
    expect(status.agents.claude).toEqual({ ready: false, kinds: [], accounts: 0, refreshing: 0, connect: "cmux ai-accounts upload claude" });
    expect(status.agents.codex).toEqual({ ready: false, kinds: [], accounts: 0, refreshing: 0, connect: "cmux ai-accounts upload codex" });
    expect(status.agents.pi.ready).toBe(false);
    expect(status.agents.opencode.ready).toBe(false);
  });

  test("a Claude login readies claude and opencode, not codex or pi", () => {
    const status = planeStatusForAccounts([account("claude")]);
    expect(status.agents.claude).toMatchObject({ ready: true, kinds: ["claude"] });
    expect(status.agents.opencode).toMatchObject({ ready: true, kinds: ["claude"] });
    expect(status.agents.codex.ready).toBe(false);
    expect(status.agents.pi.ready).toBe(false);
  });

  test("an OpenAI API key readies codex, pi, and opencode", () => {
    const status = planeStatusForAccounts([account("openai-apikey")]);
    expect(status.agents.codex).toMatchObject({ ready: true, kinds: ["openai-apikey"] });
    expect(status.agents.pi).toMatchObject({ ready: true, kinds: ["openai-apikey"] });
    expect(status.agents.opencode).toMatchObject({ ready: true, kinds: ["openai-apikey"] });
    expect(status.agents.claude.ready).toBe(false);
  });

  test("counts every account a session could land on", () => {
    const status = planeStatusForAccounts([
      account("claude", { id: "c1" }),
      account("claude", { id: "c2" }),
      account("anthropic-apikey"),
    ]);
    expect(status.agents.claude).toMatchObject({ ready: true, accounts: 3, kinds: ["claude", "anthropic-apikey"] });
    expect(status.agents.opencode.accounts).toBe(3);
    expect(status.agents.codex.accounts).toBe(0);
  });

  test("broken, expired, and cooling-down accounts do not count; refreshing is reported, not ready", () => {
    // "Ready" means what placement means: a refreshing account cannot take a
    // new session this instant, so the sole refreshing account is not ready
    // — but it is surfaced, so a client can wait rather than send the user
    // off to connect one.
    const status = planeStatusForAccounts([
      account("claude", { state: "broken" }),
      account("codex", { state: "expired" }),
      account("anthropic-apikey", { cooldownUntil: new Date(Date.now() + 60_000).toISOString() }),
      account("opencode-go", { state: "refreshing" }),
    ]);
    expect(status.agents.claude).toMatchObject({ ready: false, accounts: 0, refreshing: 0 });
    expect(status.agents.codex.ready).toBe(false);
    expect(status.agents.opencode).toMatchObject({ ready: false, kinds: [], accounts: 0, refreshing: 1 });
  });
});

describe("GET /v1/status", () => {
  const swept: string[] = [];
  const handler = createPlaneStatusHandler({
    authenticate: async (token) => (token === "crt_good" ? { teamId: "team-1", stackUserId: "u" } : null),
    sweepLeases: async (teamId) => {
      swept.push(teamId);
    },
    accounts: async () => [account("claude"), account("codex")],
  });

  test("answers a machine's route token with per-agent readiness and nothing identifying", async () => {
    const response = await handler(
      new Request("https://cmux.example/v1/status", { headers: { authorization: "Bearer crt_good" } }),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.text();
    expect(JSON.parse(body).agents.claude.ready).toBe(true);
    expect(JSON.parse(body).agents.pi).toMatchObject({ kinds: ["codex"], accounts: 1, refreshing: 0 });
    expect(body).not.toContain("person@example.com");
    expect(body).not.toContain("acct-");
    // A refresh worker that died holding its lease must not keep an account
    // "refreshing" here any longer than routing would.
    expect(swept).toEqual(["team-1"]);
  });

  test("rejects a missing or unknown token", async () => {
    expect((await handler(new Request("https://cmux.example/v1/status"))).status).toBe(401);
    expect((await handler(
      new Request("https://cmux.example/v1/status", { headers: { authorization: "Bearer crt_bad" } }),
    )).status).toBe(401);
  });
});
