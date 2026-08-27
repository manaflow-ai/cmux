import {
  listAccounts,
  listEncryptedCredentials,
  markAccountCooldown,
} from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const usageRequests = new Map<
  string,
  Promise<Awaited<ReturnType<typeof loadAccountsWithUsage>>>
>();

export async function accountsWithUsage(teamId: string) {
  const pending = usageRequests.get(teamId);
  if (pending) return await pending;

  // Provider reads fan out in parallel. Coalesce only requests that are
  // concurrently in flight; completed quota data is never served from cache.
  const request = loadAccountsWithUsage(teamId);
  usageRequests.set(teamId, request);
  try {
    return await request;
  } finally {
    usageRequests.delete(teamId);
  }
}

async function loadAccountsWithUsage(teamId: string) {
  const startedAt = performance.now();
  addCoderouterBreadcrumb("status", "Loading account usage");
  // Account metadata and encrypted envelopes are independent RDS reads.
  const rdsStartedAt = performance.now();
  const [accounts, credentials] = await Promise.all([
    listAccounts(teamId),
    listEncryptedCredentials(teamId),
  ]);
  const rdsMs = performance.now() - rdsStartedAt;
  const credentialsByAccount = new Map(
    credentials.map((credential) => [credential.accountId, credential]),
  );
  const providerStartedAt = performance.now();
  const withUsage = await Promise.all(accounts.map(async (account) => {
    if (account.provider !== "codex" || account.state !== "active") {
      return account;
    }
    try {
      const credential = await freshCredential({
        teamId,
        accountId: account.id,
        expectedRevision: credentialsByAccount.get(account.id)?.credentialRevision ?? 0,
        known: credentialsByAccount.get(account.id),
      });
      if (credential.provider !== "codex") return account;
      const response = await fetchProviderRead(() => fetch(CODEX_USAGE_URL, {
        headers: {
          authorization: `Bearer ${credential.accessToken}`,
          "chatgpt-account-id": credential.accountId,
          "user-agent": "coderouter/0.2",
        },
        cache: "no-store",
        signal: AbortSignal.timeout(5_000),
      }));
      if (!response.ok) {
        reportCoderouterFailure(
          response.status === 429 ? "provider_rate_limit" : "provider_usage",
          new Error("provider usage request failed"),
          { provider: account.provider, status: response.status },
        );
        return { ...account, usageError: `HTTP ${response.status}` };
      }
      const usage: unknown = await response.json();
      const cooldownMs = usageCooldown(usage);
      if (cooldownMs !== null) {
        await markAccountCooldown(account.id, cooldownMs);
      }
      return { ...account, usage };
    } catch (error) {
      reportCoderouterFailure("provider_usage", error, {
        provider: account.provider,
      });
      return { ...account, usageError: "unavailable" };
    }
  }));
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
