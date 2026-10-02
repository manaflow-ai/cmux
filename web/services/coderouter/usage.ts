import { listAccounts, markAccountCooldown } from "./repository";
import { freshCredential } from "./refresh";

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";

export async function accountsWithUsage(teamId: string) {
  const accounts = await listAccounts(teamId);
  return await Promise.all(accounts.map(async (account) => {
    if (account.provider !== "codex" || account.state !== "active") {
      return account;
    }
    try {
      const credential = await freshCredential({
        teamId,
        accountId: account.id,
        expectedRevision: 0,
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

function isRecord(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
