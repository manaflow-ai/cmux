import { describe, expect, test } from "bun:test";

import type { EncryptedCredential } from "../services/coderouter/encryption";
import {
  coderouterFailureSeverity,
  type CoderouterFailureOptions,
} from "../services/coderouter/observability";
import {
  CodeRouterCredentialBroken,
  CodeRouterRefreshBusy,
  createCredentialRefresher,
  type CredentialRefreshDependencies,
  type FreshCredentialInput,
} from "../services/coderouter/refresh";
import type { CodeRouterAccountSummary, CodexCredential } from "../services/coderouter/types";
import {
  createAccountsUsageLoader,
  type AccountsUsageDependencies,
} from "../services/coderouter/usage";

const ACCOUNT_ID = "00000000-0000-4000-8000-000000000001";

const account: CodeRouterAccountSummary = {
  id: ACCOUNT_ID,
  provider: "codex",
  providerAccountId: "provider-account",
  label: "person@example.com",
  state: "active",
  credentialExpiresAt: null,
  lastFailureCode: null,
  cooldownUntil: null,
  activeSessions: 0,
};

const envelope: EncryptedCredential = {
  accountId: ACCOUNT_ID,
  teamId: "team-1",
  provider: "codex",
  credentialRevision: 3,
  algorithm: "aes-256-gcm",
  ciphertext: "ciphertext",
  nonce: "nonce",
  authTag: "tag",
  encryptedDataKey: "key",
  kmsKeyId: "kms-key",
};

function codex(accessToken: string): CodexCredential {
  return {
    provider: "codex",
    accessToken,
    refreshToken: "refresh",
    idToken: "id",
    accountId: "provider-account",
    email: "person@example.com",
    expiresAt: Date.now() + 3_600_000,
  };
}

type Reported = {
  readonly failure: string;
  readonly context: Readonly<Record<string, string | number | boolean>>;
  readonly options: CoderouterFailureOptions;
};

function harness(input: {
  readonly credential: (request: FreshCredentialInput) => Promise<CodexCredential>;
  readonly usageStatus: (accessToken: string) => number;
}) {
  const credentialCalls: FreshCredentialInput[] = [];
  const usageCalls: string[] = [];
  const reported: Reported[] = [];
  const dependencies: AccountsUsageDependencies = {
    listAccounts: async () => [account],
    listEncryptedCredentials: async () => [envelope],
    markCooldown: async () => {},
    credential: async (request) => {
      credentialCalls.push(request);
      return await input.credential(request);
    },
    fetchUsage: async (credential) => {
      if (credential.provider !== "codex") throw new Error("unexpected provider");
      usageCalls.push(credential.accessToken);
      const status = input.usageStatus(credential.accessToken);
      return new Response(status === 200 ? JSON.stringify({ plan_type: "pro" }) : "{}", {
        status,
      });
    },
    report: (failure, _error, context = {}, options = {}) => {
      reported.push({ failure, context, options });
    },
  };
  return {
    load: createAccountsUsageLoader(dependencies),
    credentialCalls,
    usageCalls,
    reported,
  };
}

describe("coderouter usage reads with a rejected credential", () => {
  test("forces one refresh after a 401 and returns usage from the rotated token", async () => {
    const run = harness({
      credential: async (request) => codex(request.force ? "rotated" : "revoked"),
      usageStatus: (token) => token === "rotated" ? 200 : 401,
    });
    const result = await run.load("team-1");
    expect(run.credentialCalls.map((call) => call.force === true)).toEqual([false, true]);
    expect(run.usageCalls).toEqual(["revoked", "rotated"]);
    expect(result.accounts[0]).toMatchObject({ id: ACCOUNT_ID, usage: { plan_type: "pro" } });
    expect(run.reported).toEqual([]);
  });

  test("a revoked sign-in is returned as broken and never reported as an operator error", async () => {
    const run = harness({
      credential: async (request) => {
        if (request.force) throw new CodeRouterCredentialBroken("provider refresh token is no longer usable", true);
        return codex("revoked");
      },
      usageStatus: () => 401,
    });
    const result = await run.load("team-1");
    expect(run.usageCalls).toEqual(["revoked"]);
    expect(result.accounts[0]).toMatchObject({ id: ACCOUNT_ID, state: "broken" });
    expect(run.reported.filter((report) => report.options.fault !== "tenant")).toEqual([]);
  });

  test("a refresh owned by another request leaves the account for the next poll", async () => {
    const run = harness({
      credential: async (request) => {
        if (request.force) throw new CodeRouterRefreshBusy("credential refresh already in progress");
        return codex("revoked");
      },
      usageStatus: () => 401,
    });
    const result = await run.load("team-1");
    expect(result.accounts[0]).toMatchObject({ id: ACCOUNT_ID, state: "active", usageError: "credential_refreshing" });
    expect(run.reported).toEqual([]);
  });

  test("a freshly refreshed token that is still rejected is a tenant fault", async () => {
    const run = harness({
      credential: async (request) => codex(request.force ? "rotated" : "revoked"),
      usageStatus: () => 401,
    });
    const result = await run.load("team-1");
    expect(result.accounts[0]).toMatchObject({ usageError: "HTTP 401" });
    expect(run.reported).toHaveLength(1);
    expect(run.reported[0]).toMatchObject({
      failure: "provider_usage",
      context: { provider: "codex", status: 401 },
      options: { fault: "tenant" },
    });
  });

  test("provider outages on the usage endpoint stay alertable", async () => {
    const run = harness({
      credential: async () => codex("valid"),
      usageStatus: () => 503,
    });
    await run.load("team-1");
    expect(run.credentialCalls).toHaveLength(1);
    expect(run.reported).toHaveLength(1);
    expect(run.reported[0]?.options.fault).toBeUndefined();
  });
});

describe("coderouter terminal refresh failures", () => {
  test("a revoked refresh token is reported once as a tenant fault", async () => {
    const reported: Reported[] = [];
    const dependencies: CredentialRefreshDependencies = {
      read: async () => ({ envelope, credential: codex("old") }),
      decrypt: async () => codex("old"),
      claim: async () => "lease-1",
      release: async () => {},
      refresh: async () => {
        throw new Error("refresh_token_reused");
      },
      encrypt: async () => envelope,
      complete: async () => {},
      fail: async () => {},
      isTerminal: () => true,
      failureCode: () => "refresh_token_reused",
      report: (failure, _error, context = {}, options = {}) => {
        reported.push({ failure, context, options });
      },
    };
    const refresh = createCredentialRefresher(dependencies);
    await expect(refresh({
      teamId: "team-1",
      accountId: ACCOUNT_ID,
      expectedRevision: 3,
      force: true,
    })).rejects.toBeInstanceOf(CodeRouterCredentialBroken);
    expect(reported).toHaveLength(1);
    expect(reported[0]).toMatchObject({
      failure: "provider_refresh",
      context: { terminal: true },
      options: { fault: "tenant" },
    });
  });

  test("an operator refresh misconfiguration stays an error", async () => {
    const reported: Reported[] = [];
    const refresh = createCredentialRefresher(refreshDependencies({
      failureCode: () => "invalid_client",
      report: (failure, _error, context = {}, options = {}) => {
        reported.push({ failure, context, options });
      },
    }));
    await expect(refresh({ teamId: "team-1", accountId: ACCOUNT_ID, expectedRevision: 3, force: true }))
      .rejects.toBeInstanceOf(CodeRouterCredentialBroken);
    expect(reported).toHaveLength(1);
    expect(reported[0]?.options.fault).toBeUndefined();
  });

  test("a forced refresh reuses a token another request already rotated", async () => {
    let providerRefreshes = 0;
    const refresh = createCredentialRefresher(refreshDependencies({
      read: async () => ({ envelope: { ...envelope, credentialRevision: 4 }, credential: codex("rotated") }),
      refresh: async () => {
        providerRefreshes++;
        return codex("again");
      },
    }));
    const result = await refresh({ teamId: "team-1", accountId: ACCOUNT_ID, expectedRevision: 3, force: true });
    expect(result.provider === "codex" ? result.accessToken : null).toBe("rotated");
    expect(providerRefreshes).toBe(0);
  });

  test("tenant faults are warnings in Sentry and PostHog; operator faults stay errors", () => {
    expect(coderouterFailureSeverity("provider_refresh", { fault: "tenant" })).toEqual({
      sentry: "warning",
      posthog: "warning",
    });
    expect(coderouterFailureSeverity("provider_refresh", {})).toEqual({
      sentry: "error",
      posthog: "warning",
    });
    expect(coderouterFailureSeverity("rds", {})).toEqual({
      sentry: "error",
      posthog: "error",
    });
  });
});

function refreshDependencies(
  overrides: Partial<CredentialRefreshDependencies> = {},
): CredentialRefreshDependencies {
  return {
    read: async () => ({ envelope, credential: codex("old") }),
    decrypt: async () => codex("old"),
    claim: async () => "lease-1",
    release: async () => {},
    refresh: async () => {
      throw new Error("rejected");
    },
    encrypt: async () => envelope,
    complete: async () => {},
    fail: async () => {},
    isTerminal: () => true,
    failureCode: () => "refresh_token_reused",
    report: () => {},
    ...overrides,
  };
}
