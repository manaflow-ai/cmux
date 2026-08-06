import { unstable_cache } from "next/cache";
import {
  listAccounts,
  listEncryptedCredentials,
  markAccountCooldown,
} from "./repository";
import { freshCredential } from "./refresh";

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const USAGE_CACHE_MS = 15_000;
const MAX_CACHED_TEAMS = 256;
const usageCache = new Map<string, {
  readonly expiresAt: number;
  readonly accounts: Awaited<ReturnType<typeof loadAccountsWithUsage>>;
}>();
const usageRequests = new Map<
  string,
  Promise<Awaited<ReturnType<typeof loadAccountsWithUsage>>>
>();
const sharedAccountsWithUsage = unstable_cache(
  loadAccountsWithUsage,
  ["coderouter-usage-v1"],
  { revalidate: USAGE_CACHE_MS / 1_000 },
);

export async function accountsWithUsage(teamId: string) {
  const cached = usageCache.get(teamId);
  if (cached && cached.expiresAt > Date.now()) return cached.accounts;
  const pending = usageRequests.get(teamId);
  if (pending) return await pending;

  // Vercel's encrypted data cache is shared across function instances. It
  // stores only account summaries and provider usage, never credentials.
  const request = sharedAccountsWithUsage(teamId);
  usageRequests.set(teamId, request);
  try {
    const accounts = await request;
    if (usageCache.size >= MAX_CACHED_TEAMS && !usageCache.has(teamId)) {
      const oldest = usageCache.keys().next().value;
      if (oldest !== undefined) usageCache.delete(oldest);
    }
    usageCache.delete(teamId);
    usageCache.set(teamId, {
      expiresAt: Date.now() + USAGE_CACHE_MS,
      accounts,
    });
    return accounts;
  } finally {
    usageRequests.delete(teamId);
  }
}

async function loadAccountsWithUsage(teamId: string) {
  // Account metadata and encrypted envelopes are independent RDS reads.
  const [accounts, credentials] = await Promise.all([
    listAccounts(teamId),
    listEncryptedCredentials(teamId),
  ]);
  const credentialsByAccount = new Map(
    credentials.map((credential) => [credential.accountId, credential]),
  );
  return await Promise.all(accounts.map(async (account) => {
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
      const response = await fetch(CODEX_USAGE_URL, {
        headers: {
          authorization: `Bearer ${credential.accessToken}`,
          "chatgpt-account-id": credential.accountId,
          "user-agent": "coderouter/0.2",
        },
        cache: "no-store",
        signal: AbortSignal.timeout(5_000),
      });
      if (!response.ok) {
        return { ...account, usageError: `HTTP ${response.status}` };
      }
      const usage: unknown = await response.json();
      const cooldownMs = usageCooldown(usage);
      if (cooldownMs !== null) {
        await markAccountCooldown(account.id, cooldownMs);
      }
      return { ...account, usage };
    } catch {
      return { ...account, usageError: "unavailable" };
    }
  }));
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
