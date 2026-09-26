import { after } from "next/server";
import type { CoderouterAccountAccess } from "./accountAccess";
import type { EncryptedCredential } from "./encryption";
import {
  claimAccountUsageRefresh,
  listAccounts,
  listEncryptedCredentials,
  markAccountCooldown,
  storeAccountUsage,
  storedAccountUsage,
  type StoredAccountUsage,
} from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";

/**
 * Status serves each account's last quota reading instead of calling the
 * provider once per account per request, which made `cr` wait on the slowest
 * of up to ~100 ChatGPT reads. A reading younger than `USAGE_FRESH_MS` is
 * served as is. An older one is served and refreshed after the response. One
 * older than `USAGE_MAX_STALE_MS`, or a missing one, is read before answering,
 * so an occasional `cr` never shows a long-stale quota. Routing does not read
 * these numbers; it uses `cooldown_until`, which a refresh still sets.
 */
export const USAGE_FRESH_MS = 30_000;
export const USAGE_MAX_STALE_MS = 10 * 60_000;

type Account = Awaited<ReturnType<typeof listAccounts>>[number];
type Reading = { readonly usage: unknown } | { readonly usageError: string };

export type UsageDependencies = {
  readonly listAccounts: typeof listAccounts;
  readonly storedUsage: (teamId: string) => Promise<ReadonlyMap<string, StoredAccountUsage>>;
  readonly claimRefresh: typeof claimAccountUsageRefresh;
  readonly credentials: (teamId: string) => Promise<readonly EncryptedCredential[]>;
  readonly read: (teamId: string, accountId: string, credential: EncryptedCredential | undefined) => Promise<Reading>;
  readonly store: typeof storeAccountUsage;
  /** Runs work after the response; must absorb its rejection. */
  readonly defer: (task: Promise<unknown>) => void;
  readonly now: () => number;
};

const defaultDependencies: UsageDependencies = {
  listAccounts,
  storedUsage: storedAccountUsage,
  claimRefresh: claimAccountUsageRefresh,
  credentials: listEncryptedCredentials,
  read: readCodexUsage,
  store: storeAccountUsage,
  defer: deferAfterResponse,
  now: Date.now,
};

export function createAccountsWithUsage(dependencies: UsageDependencies) {
  const usageRequests = new Map<string, ReturnType<typeof load>>();

  async function accountsWithUsage(teamId: string, access?: CoderouterAccountAccess) {
    const key = JSON.stringify([teamId, access]);
    const pending = usageRequests.get(key);
    if (pending) return await pending;
    // Coalesce only requests that are concurrently in flight.
    const request = load(teamId, access);
    usageRequests.set(key, request);
    try {
      return await request;
    } finally {
      usageRequests.delete(key);
    }
  }

  /** Reads, stores, and returns fresh readings for the given accounts. */
  async function refresh(teamId: string, accountIds: readonly string[]) {
    const credentials = new Map(
      (await dependencies.credentials(teamId)).map((credential) => [credential.accountId, credential]),
    );
    const readings = new Map<string, StoredAccountUsage>();
    await Promise.all(accountIds.map(async (accountId) => {
      const reading = await dependencies.read(teamId, accountId, credentials.get(accountId));
      const fetchedAt = new Date(dependencies.now());
      readings.set(accountId, {
        usage: "usage" in reading ? reading.usage : null,
        usageError: "usageError" in reading ? reading.usageError : null,
        fetchedAt,
      });
      try {
        await dependencies.store(teamId, accountId, reading, fetchedAt);
      } catch (error) {
        // The reading is still returned; the next view reads again.
        reportCoderouterFailure("rds", error, { operation: "store_account_usage" });
      }
    }));
    return readings;
  }

  async function refreshInBackground(teamId: string, accountIds: readonly string[]) {
    const now = dependencies.now();
    const claimed = await dependencies.claimRefresh(
      teamId,
      accountIds,
      new Date(now),
      new Date(now - USAGE_FRESH_MS),
    );
    if (claimed.length > 0) await refresh(teamId, claimed);
  }

  async function load(teamId: string, access?: CoderouterAccountAccess) {
    const startedAt = performance.now();
    addCoderouterBreadcrumb("status", "Loading account usage");
    const rdsStartedAt = performance.now();
    const [accounts, stored] = await Promise.all([
      dependencies.listAccounts(teamId, access),
      dependencies.storedUsage(teamId),
    ]);
    const rdsMs = performance.now() - rdsStartedAt;

    const now = dependencies.now();
    const blocking: string[] = [];
    const stale: string[] = [];
    for (const account of accounts) {
      if (!hasUsage(account)) continue;
      const reading = stored.get(account.id);
      const age = reading ? now - reading.fetchedAt.getTime() : Number.POSITIVE_INFINITY;
      if (age > USAGE_MAX_STALE_MS) blocking.push(account.id);
      else if (age > USAGE_FRESH_MS) stale.push(account.id);
    }

    const providerStartedAt = performance.now();
    const live = blocking.length > 0 ? await refresh(teamId, blocking) : new Map<string, StoredAccountUsage>();
    const providerMs = performance.now() - providerStartedAt;
    if (stale.length > 0) dependencies.defer(refreshInBackground(teamId, stale));
    addCoderouterBreadcrumb("status", "Account usage resolved", {
      account_count: accounts.length,
      provider_read_count: blocking.length,
      background_refresh_count: stale.length,
      provider_ms: Math.round(providerMs),
    });

    let oldest = now;
    const withUsage = accounts.map((account) => {
      if (!hasUsage(account)) return account;
      const reading = live.get(account.id) ?? stored.get(account.id);
      if (!reading) return account;
      oldest = Math.min(oldest, reading.fetchedAt.getTime());
      return reading.usageError === null
        ? { ...account, usage: reading.usage }
        : { ...account, usageError: reading.usageError };
    });
    return {
      accounts: withUsage,
      usageAsOf: new Date(oldest).toISOString(),
      usageGeneratedAtMs: oldest,
      cacheMaxAgeSeconds: USAGE_FRESH_MS / 1_000,
      timing: {
        rdsMs,
        providerMs,
        totalMs: performance.now() - startedAt,
      },
    };
  }

  return { accountsWithUsage };
}

export const { accountsWithUsage } = createAccountsWithUsage(defaultDependencies);

function hasUsage(account: Account): boolean {
  return account.provider === "codex" && account.state === "active";
}

async function readCodexUsage(
  teamId: string,
  accountId: string,
  known: EncryptedCredential | undefined,
): Promise<Reading> {
  try {
    const credential = await freshCredential({
      teamId,
      accountId,
      expectedRevision: known?.credentialRevision ?? 0,
      known,
    });
    if (credential.provider !== "codex") return { usageError: "unavailable" };
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
        { provider: "codex", status: response.status },
      );
      return { usageError: `HTTP ${response.status}` };
    }
    const usage: unknown = await response.json();
    const cooldownMs = usageCooldown(usage);
    if (cooldownMs !== null) {
      await markAccountCooldown(accountId, cooldownMs);
    }
    return { usage };
  } catch (error) {
    reportCoderouterFailure("provider_usage", error, { provider: "codex" });
    return { usageError: "unavailable" };
  }
}

function deferAfterResponse(task: Promise<unknown>): void {
  const settled = task.catch((error: unknown) => {
    reportCoderouterFailure("provider_usage", error, { operation: "background_usage_refresh" });
  });
  try {
    after(settled);
  } catch {
    // Unit tests and scripts have no Next request scope; the task already runs.
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
