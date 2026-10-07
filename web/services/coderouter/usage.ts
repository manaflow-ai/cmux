import type { CoderouterAccountAccess } from "./accountAccess";
import type { EncryptedCredential } from "./encryption";
import {
  listAccounts,
  listEncryptedCredentials,
  markAccountCooldown,
} from "./repository";
import {
  CodeRouterCredentialBroken,
  CodeRouterRefreshBusy,
  freshCredential,
} from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";
import type { CodeRouterAccountSummary, CodeRouterCredential } from "./types";

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";

export type AccountsUsageDependencies = {
  readonly listAccounts: typeof listAccounts;
  readonly listEncryptedCredentials: typeof listEncryptedCredentials;
  readonly markCooldown: (accountId: string, durationMs: number) => Promise<void>;
  readonly credential: typeof freshCredential;
  readonly fetchUsage: (credential: CodeRouterCredential) => Promise<Response>;
  readonly report: typeof reportCoderouterFailure;
  /** Consecutive usage-read timeouts per account; defaults to this instance's tracker. */
  readonly timeoutStreaks?: UsageTimeoutStreaks;
};

/**
 * Consecutive timed-out polls after which one account's usage read is
 * reported as an error instead of a transient upstream warning.
 */
export const USAGE_TIMEOUT_ERROR_STREAK = 3;
const MAX_TRACKED_TIMEOUT_ACCOUNTS = 1_000;

export type UsageTimeoutStreaks = {
  readonly record: (accountId: string) => number;
  readonly clear: (accountId: string) => void;
};

/**
 * Counts consecutive usage-read timeouts per account on this server
 * instance. Best effort: a new instance starts at zero, which delays an
 * escalation but never invents one. Bounded so a long-lived instance
 * cannot grow it without limit.
 */
export function createUsageTimeoutStreaks(): UsageTimeoutStreaks {
  const streaks = new Map<string, number>();
  return {
    record: (accountId) => {
      const next = (streaks.get(accountId) ?? 0) + 1;
      streaks.delete(accountId);
      streaks.set(accountId, next);
      if (streaks.size > MAX_TRACKED_TIMEOUT_ACCOUNTS) {
        const oldest = streaks.keys().next().value;
        if (oldest !== undefined) streaks.delete(oldest);
      }
      return next;
    },
    clear: (accountId) => {
      streaks.delete(accountId);
    },
  };
}

const defaultTimeoutStreaks = createUsageTimeoutStreaks();

type AccountWithUsage = CodeRouterAccountSummary & {
  readonly usage?: unknown;
  readonly usageError?: string;
};

export function createAccountsUsageLoader(dependencies: AccountsUsageDependencies) {
  return async (teamId: string, access?: CoderouterAccountAccess) => {
    const startedAt = performance.now();
    addCoderouterBreadcrumb("status", "Loading account usage");
    // Account metadata and encrypted envelopes are independent RDS reads.
    const rdsStartedAt = performance.now();
    const [accounts, credentials] = await Promise.all([
      dependencies.listAccounts(teamId, access),
      dependencies.listEncryptedCredentials(teamId),
    ]);
    const rdsMs = performance.now() - rdsStartedAt;
    const credentialsByAccount = new Map(
      credentials.map((credential) => [credential.accountId, credential]),
    );
    const providerStartedAt = performance.now();
    const withUsage = await Promise.all(accounts.map((account) =>
      account.provider === "codex" && account.state === "active"
        ? accountUsage(dependencies, teamId, account, credentialsByAccount.get(account.id))
        : account
    ));
    addCoderouterBreadcrumb("status", "Provider usage fanout completed", {
      account_count: accounts.length,
      provider_ms: Math.round(performance.now() - providerStartedAt),
    });
    return {
      accounts: withUsage,
      usageAsOf: new Date().toISOString(),
      usageGeneratedAtMs: Date.now(),
      cacheMaxAgeSeconds: 0,
      timing: {
        rdsMs,
        providerMs: performance.now() - providerStartedAt,
        totalMs: performance.now() - startedAt,
      },
    };
  };
}

async function accountUsage(
  dependencies: AccountsUsageDependencies,
  teamId: string,
  account: CodeRouterAccountSummary,
  known: EncryptedCredential | undefined,
): Promise<AccountWithUsage> {
  try {
    const credential = await dependencies.credential({
      teamId,
      accountId: account.id,
      expectedRevision: known?.credentialRevision ?? 0,
      known,
    });
    if (credential.provider !== "codex") return account;
    let response = await dependencies.fetchUsage(credential);
    if (response.status === 401) {
      // Release the rejected response's connection before the retry.
      await response.body?.cancel().catch(() => undefined);
      const refreshed = await refreshRejectedCredential(dependencies, teamId, account, known);
      if (refreshed.provider !== "codex") return account;
      response = await dependencies.fetchUsage(refreshed);
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => undefined);
      dependencies.report(
        response.status === 429 ? "provider_rate_limit" : "provider_usage",
        new Error("provider usage request failed"),
        { provider: account.provider, status: response.status },
        // A token the provider just minted and still rejects means the
        // workspace itself no longer grants access: the team's to fix.
        response.status === 401 ? { fault: "tenant" } : {},
      );
      return { ...account, usageError: `HTTP ${response.status}` };
    }
    const usage: unknown = await response.json();
    (dependencies.timeoutStreaks ?? defaultTimeoutStreaks).clear(account.id);
    const cooldownMs = usageCooldown(usage);
    if (cooldownMs !== null) {
      await dependencies.markCooldown(account.id, cooldownMs);
    }
    return { ...account, usage };
  } catch (error) {
    // The refresher already reported a revoked sign-in as a tenant fault and
    // marked the account broken; show that state now instead of next poll.
    if (error instanceof CodeRouterCredentialBroken && error.reported) {
      return { ...account, state: "broken", usageError: "credential_broken" };
    }
    // Another request holds the refresh lease and will settle this account.
    if (error instanceof CodeRouterRefreshBusy) {
      return { ...account, usageError: "credential_refreshing" };
    }
    if (isTimeout(error)) return reportUsageTimeout(dependencies, account, error);
    dependencies.report("provider_usage", error, {
      provider: account.provider,
    });
    return { ...account, usageError: "unavailable" };
  }
}

/**
 * The usage endpoint answers in ~0.35 s at p50 and ~2 s at p99; a read past
 * the 5 s budget is almost always a stalled response body. The account list
 * is polled, so the next poll retries: one timeout is an upstream warning,
 * and only an account that keeps timing out escalates to an error.
 */
function reportUsageTimeout(
  dependencies: AccountsUsageDependencies,
  account: CodeRouterAccountSummary,
  error: unknown,
): AccountWithUsage {
  const consecutive = (dependencies.timeoutStreaks ?? defaultTimeoutStreaks).record(account.id);
  dependencies.report(
    "provider_usage",
    error,
    { provider: account.provider, timeout: true, consecutive },
    consecutive >= USAGE_TIMEOUT_ERROR_STREAK ? {} : { fault: "upstream" },
  );
  return { ...account, usageError: "timeout" };
}

function isTimeout(error: unknown): boolean {
  return error instanceof Error && error.name === "TimeoutError";
}

/**
 * A 401 on the usage read means the stored access token was revoked before
 * its recorded expiry. Force one refresh, the same recovery the model routes
 * use: a rotated token answers the retry, and a revoked sign-in is marked
 * broken by the refresher so the dashboard asks the team to reconnect it and
 * later polls skip it instead of re-reading a dead credential forever.
 */
async function refreshRejectedCredential(
  dependencies: AccountsUsageDependencies,
  teamId: string,
  account: CodeRouterAccountSummary,
  known: EncryptedCredential | undefined,
): Promise<CodeRouterCredential> {
  addCoderouterBreadcrumb("refresh", "Refreshing credential rejected by usage read", {
    provider: account.provider,
  }, "warning");
  return await dependencies.credential({
    teamId,
    accountId: account.id,
    expectedRevision: known?.credentialRevision ?? 0,
    force: true,
  });
}

const loadAccountsWithUsage = createAccountsUsageLoader({
  listAccounts,
  listEncryptedCredentials,
  markCooldown: (accountId, durationMs) => markAccountCooldown(accountId, durationMs),
  credential: freshCredential,
  fetchUsage: (credential) => {
    if (credential.provider !== "codex") {
      throw new Error("usage reads are only supported for Codex sign-ins");
    }
    return fetchProviderRead(() => fetch(CODEX_USAGE_URL, {
      headers: {
        authorization: `Bearer ${credential.accessToken}`,
        "chatgpt-account-id": credential.accountId,
        "user-agent": "coderouter/0.2",
      },
      cache: "no-store",
      signal: AbortSignal.timeout(5_000),
    }));
  },
  report: reportCoderouterFailure,
});

const usageRequests = new Map<
  string,
  Promise<Awaited<ReturnType<typeof loadAccountsWithUsage>>>
>();

export async function accountsWithUsage(teamId: string, access?: CoderouterAccountAccess) {
  const key = JSON.stringify([teamId, access]);
  const pending = usageRequests.get(key);
  if (pending) return await pending;

  // Provider reads fan out in parallel. Coalesce only requests that are
  // concurrently in flight; completed quota data is never served from cache.
  const request = loadAccountsWithUsage(teamId, access);
  usageRequests.set(key, request);
  try {
    return await request;
  } finally {
    usageRequests.delete(key);
  }
}

function usageCooldown(value: unknown): number | null {
  if (!isRecord(value) || !isRecord(value.rate_limit)) return null;
  const rate = value.rate_limit;
  if (rate.limit_reached !== true && rate.allowed !== false) return null;
  const windows = [rate.primary_window, rate.secondary_window].filter(isRecord);
  const resetSeconds = windows
    .map((window) => window.reset_after_seconds)
    .filter((seconds): seconds is number =>
      typeof seconds === "number" && Number.isFinite(seconds) && seconds > 0
    );
  return (resetSeconds.length > 0 ? Math.min(...resetSeconds) : 60) * 1_000;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
