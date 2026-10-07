import { describe, expect, test } from "bun:test";

import type { EncryptedCredential } from "../services/coderouter/encryption";
import {
  coderouterFailureSeverity,
  type CoderouterFailureOptions,
} from "../services/coderouter/observability";
import {
  CodeRouterCredentialBroken,
  createCredentialRefresher,
  type CredentialRefreshDependencies,
} from "../services/coderouter/refresh";
import type { CodeRouterAccountSummary, CodexCredential } from "../services/coderouter/types";
import {
  createAccountsUsageLoader,
  createUsageTimeoutStreaks,
  USAGE_TIMEOUT_ERROR_STREAK,
} from "../services/coderouter/usage";

const ACCOUNT_ID = "00000000-0000-4000-8000-000000000002";

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
  credentialRevision: 1,
  algorithm: "aes-256-gcm",
  ciphertext: "ciphertext",
  nonce: "nonce",
  authTag: "tag",
  encryptedDataKey: "key",
  kmsKeyId: "kms-key",
};

function codex(): CodexCredential {
  return {
    provider: "codex",
    accessToken: "access",
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

/** One loader whose usage reads follow `outcomes` in order, sharing one streak tracker. */
function poller(outcomes: Array<"timeout" | "ok">) {
  const reported: Reported[] = [];
  const load = createAccountsUsageLoader({
    listAccounts: async () => [account],
    listEncryptedCredentials: async () => [envelope],
    markCooldown: async () => {},
    credential: async () => codex(),
    fetchUsage: async () => {
      if (outcomes.shift() === "timeout") {
        // What AbortSignal.timeout raises when the body stalls past the budget.
        throw new DOMException("The operation timed out.", "TimeoutError");
      }
      return Response.json({ plan_type: "pro" });
    },
    report: (failure, _error, context = {}, options = {}) => {
      reported.push({ failure, context, options });
    },
    timeoutStreaks: createUsageTimeoutStreaks(),
  });
  return { load, reported };
}

describe("coderouter usage read timeouts", () => {
  test("a single usage-read timeout is an upstream warning, not an operator error", async () => {
    const run = poller(["timeout"]);
    const result = await run.load("team-1");
    expect(result.accounts[0]).toMatchObject({ usageError: "timeout" });
    expect(run.reported).toHaveLength(1);
    expect(run.reported[0]).toMatchObject({
      failure: "provider_usage",
      context: { provider: "codex", timeout: true, consecutive: 1 },
      options: { fault: "upstream" },
    });
  });

  test("an account that times out on consecutive polls escalates to an error", async () => {
    const run = poller(Array.from({ length: USAGE_TIMEOUT_ERROR_STREAK }, () => "timeout" as const));
    for (let poll = 0; poll < USAGE_TIMEOUT_ERROR_STREAK; poll++) await run.load("team-1");
    const last = run.reported.at(-1);
    expect(last?.context.consecutive).toBe(USAGE_TIMEOUT_ERROR_STREAK);
    expect(last?.options.fault).toBeUndefined();
    expect(run.reported.slice(0, -1).every((report) => report.options.fault === "upstream")).toBe(true);
  });

  test("a successful read resets the streak", async () => {
    const outcomes: Array<"timeout" | "ok"> = [];
    for (let index = 1; index < USAGE_TIMEOUT_ERROR_STREAK; index++) outcomes.push("timeout");
    outcomes.push("ok", "timeout");
    const run = poller(outcomes);
    for (let poll = 0; poll < outcomes.length + 1; poll++) await run.load("team-1");
    const last = run.reported.at(-1);
    expect(last?.context.consecutive).toBe(1);
    expect(last?.options.fault).toBe("upstream");
  });

  test("upstream faults are warnings in Sentry and PostHog", () => {
    expect(coderouterFailureSeverity("provider_usage", { fault: "upstream" })).toEqual({
      sentry: "warning",
      posthog: "warning",
    });
  });
});

describe("coderouter refresh failure codes", () => {
  function refreshWith(code: string) {
    const reported: Reported[] = [];
    const dependencies: CredentialRefreshDependencies = {
      read: async () => ({ envelope, credential: codex() }),
      decrypt: async () => codex(),
      claim: async () => "lease-1",
      release: async () => {},
      refresh: async () => {
        throw new Error("rejected");
      },
      encrypt: async () => envelope,
      complete: async () => {},
      fail: async () => {},
      isTerminal: () => true,
      failureCode: () => code,
      report: (failure, _error, context = {}, options = {}) => {
        reported.push({ failure, context, options });
      },
    };
    return { refresh: createCredentialRefresher(dependencies), reported };
  }

  test("OpenAI's revoked sign-in code is a tenant fault and the code is reported", async () => {
    const run = refreshWith("refresh_token_invalidated");
    await expect(run.refresh({ teamId: "team-1", accountId: ACCOUNT_ID, expectedRevision: 1, force: true }))
      .rejects.toBeInstanceOf(CodeRouterCredentialBroken);
    expect(run.reported[0]).toMatchObject({
      failure: "provider_refresh",
      context: { terminal: true, failure_code: "refresh_token_invalidated" },
      options: { fault: "tenant" },
    });
  });

  test("a client misconfiguration stays an operator error with its code", async () => {
    const run = refreshWith("invalid_client");
    await expect(run.refresh({ teamId: "team-1", accountId: ACCOUNT_ID, expectedRevision: 1, force: true }))
      .rejects.toBeInstanceOf(CodeRouterCredentialBroken);
    expect(run.reported[0]?.context.failure_code).toBe("invalid_client");
    expect(run.reported[0]?.options.fault).toBeUndefined();
  });
});
