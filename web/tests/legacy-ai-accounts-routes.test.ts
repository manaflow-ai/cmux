import { describe, expect, mock, test } from "bun:test";

import type { ClaudeAccountDescription } from "../services/coderouter/claudeUpstream";
import type { CodeRouterAccountSummary } from "../services/coderouter/types";
import {
  AI_ACCOUNTS_UPLOAD_MOVED,
  makeLegacyAiAccountsHandlers,
  type LegacyAiAccountsDependencies,
} from "../services/subrouter/legacyAiAccounts";

// Regression for manaflow-ai/cmux#46671: `cmux ai-accounts list` (shipped
// macOS 0.65.x) calls `/api/subrouter/accounts`, which brokered a retired
// hosted Subrouter and failed with an upstream 502 for every team. The route
// now answers from the team's CodeRouter accounts and never makes an
// outbound request.

const TEAM = "team-a";
const NATIVE_ID = "11111111-1111-4111-8111-111111111111";
const CLAUDE_ID = "22222222-2222-4222-8222-222222222222";

const nativeAccount: CodeRouterAccountSummary = {
  id: NATIVE_ID,
  provider: "codex",
  providerAccountId: "provider-secret-identity",
  label: "Max work",
  state: "active",
  credentialExpiresAt: null,
  lastFailureCode: null,
  cooldownUntil: null,
  activeSessions: 0,
};

const claudeAccount: ClaudeAccountDescription = {
  id: CLAUDE_ID,
  kind: "anthropic_oauth",
  label: "Claude Max",
  identifier: "sk-ant-oat…abcd",
  region: null,
  modelIds: {},
  state: "disabled",
  cooldownUntil: null,
  lastFailureCode: null,
  lastUsedAt: null,
  createdAt: "2026-11-01T00:00:00.000Z",
  updatedAt: "2026-11-01T00:00:00.000Z",
};

function harness(overrides: Partial<LegacyAiAccountsDependencies> = {}) {
  const resolve = mock(async () => ({
    ok: true as const,
    value: {
      user: { id: "user-1" },
      team: { teamId: TEAM, teamName: "Team A", use: true, manageAccounts: true },
      access: { kind: "user" as const, userId: "user-1" },
    },
  }));
  const dependencies = {
    resolve,
    listNative: mock(async () => [nativeAccount]),
    listClaude: mock(async () => [claudeAccount]),
    removeNative: mock(async () => ({ removed: false })),
    removeClaude: mock(async () => ({ removed: false })),
    capture: mock(() => {}),
    isViewOpen: () => false,
    report: mock(() => {}),
    ...overrides,
  };
  return {
    dependencies,
    handlers: makeLegacyAiAccountsHandlers(
      dependencies as unknown as LegacyAiAccountsDependencies,
    ),
  };
}

function nativeRequest(path: string, method = "GET"): Request {
  return new Request(`https://cmux.test${path}`, {
    method,
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "x-cmux-team-id": TEAM,
    },
  });
}

describe("legacy /api/subrouter/accounts served from CodeRouter", () => {
  test("lists the team's CodeRouter and Claude accounts without contacting hosted Subrouter", async () => {
    const originalFetch = globalThis.fetch;
    const outbound = mock(async () => Response.json({}, { status: 503 }));
    globalThis.fetch = outbound as unknown as typeof fetch;
    try {
      const { handlers, dependencies } = harness();
      const response = await handlers.GET(nativeRequest("/api/subrouter/accounts"));
      const text = await response.text();

      expect(response.status).toBe(200);
      expect(JSON.parse(text)).toEqual({
        teamId: TEAM,
        accounts: [
          {
            id: NATIVE_ID,
            kind: "codex",
            label: "Max work",
            state: "active",
            health: { ok: true },
          },
          {
            id: CLAUDE_ID,
            kind: "claude-anthropic_oauth",
            label: "Claude Max",
            createdAt: "2026-11-01T00:00:00.000Z",
            state: "disabled",
            health: { ok: false },
          },
        ],
      });
      expect(text).not.toContain("provider-secret-identity");
      expect(text).not.toContain("sk-ant-oat");
      expect(outbound).not.toHaveBeenCalled();
      expect(dependencies.listNative).toHaveBeenCalledWith(TEAM, { kind: "user", userId: "user-1" });
      expect(dependencies.listClaude).toHaveBeenCalledWith(TEAM, { kind: "user", userId: "user-1" });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("keeps the resolver's rejection, so a non-member team stays 403", async () => {
    const { handlers, dependencies } = harness({
      resolve: mock(async () => ({
        ok: false as const,
        response: Response.json({ error: "team_not_found" }, { status: 403 }),
      })) as unknown as LegacyAiAccountsDependencies["resolve"],
    });
    const response = await handlers.GET(nativeRequest("/api/subrouter/accounts?teamId=other"));
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "team_not_found" });
    expect(dependencies.listNative).not.toHaveBeenCalled();
  });

  test("reports a store outage as a retryable 503 instead of an upstream 502", async () => {
    const report = mock(() => {});
    const { handlers } = harness({
      listClaude: mock(async () => {
        throw new Error("rds down");
      }),
      report,
    });
    const response = await handlers.GET(nativeRequest("/api/subrouter/accounts"));
    expect(response.status).toBe(503);
    expect((await response.json()).retryable).toBe(true);
    expect(report).toHaveBeenCalledTimes(1);
  });

  test("counts an opened view once, with unhealthy accounts", async () => {
    const capture = mock(() => {});
    const { handlers } = harness({ capture, isViewOpen: () => true });
    await handlers.GET(nativeRequest("/api/subrouter/accounts"));
    expect(capture).toHaveBeenCalledWith({
      event: "coderouter_account_status_viewed",
      teamId: TEAM,
      properties: { source: "legacy_dashboard", account_count: 2, account_error_count: 1 },
    });
  });

  test("removes a native account, then a Claude account, by id", async () => {
    const native = harness({ removeNative: mock(async () => ({ removed: true })) });
    const removedNative = await native.handlers.DELETE(
      nativeRequest(`/api/subrouter/accounts/${NATIVE_ID}`, "DELETE"),
      { params: Promise.resolve({ accountId: NATIVE_ID }) },
    );
    expect(removedNative.status).toBe(200);
    expect(await removedNative.json()).toEqual({ ok: true, teamId: TEAM });
    expect(native.dependencies.removeClaude).not.toHaveBeenCalled();

    const claude = harness({ removeClaude: mock(async () => ({ removed: true })) });
    const removedClaude = await claude.handlers.DELETE(
      nativeRequest(`/api/subrouter/accounts/${CLAUDE_ID}`, "DELETE"),
      { params: Promise.resolve({ accountId: CLAUDE_ID }) },
    );
    expect(removedClaude.status).toBe(200);
    expect(claude.dependencies.removeNative).toHaveBeenCalledTimes(1);
    expect(claude.dependencies.removeClaude).toHaveBeenCalledWith(
      TEAM,
      CLAUDE_ID,
      { kind: "user", userId: "user-1" },
    );
  });

  test("answers 404 for an unknown id and 400 for a non-UUID id", async () => {
    const { handlers, dependencies } = harness();
    const missing = await handlers.DELETE(
      nativeRequest(`/api/subrouter/accounts/${NATIVE_ID}`, "DELETE"),
      { params: Promise.resolve({ accountId: NATIVE_ID }) },
    );
    expect(missing.status).toBe(404);

    const legacyId = await handlers.DELETE(
      nativeRequest("/api/subrouter/accounts/old%40example.com", "DELETE"),
      { params: Promise.resolve({ accountId: "old@example.com" }) },
    );
    expect(legacyId.status).toBe(400);
    expect(dependencies.removeNative).toHaveBeenCalledTimes(1);
  });

  test("points uploads at CodeRouter's add flows", async () => {
    const { handlers } = harness();
    const response = await handlers.POST(nativeRequest("/api/subrouter/accounts", "POST"));
    expect(response.status).toBe(410);
    expect(await response.json()).toEqual(AI_ACCOUNTS_UPLOAD_MOVED);
  });
});
