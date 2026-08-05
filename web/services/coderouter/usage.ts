import { listAccounts } from "./repository";
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
      return { ...account, usage };
    } catch {
      return { ...account, usageError: "unavailable" };
    }
  }));
}
