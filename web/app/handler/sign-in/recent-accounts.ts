export const RECENT_SIGN_IN_ACCOUNTS_STORAGE_KEY = "cmux.signIn.recentAccounts.v1";
export const RECENT_SIGN_IN_ACCOUNTS_MAX = 6;

export type RememberedSignInAccountInput = {
  id?: string | null;
  email?: string | null;
  name?: string | null;
};

export type RememberedSignInAccount = {
  id: string;
  email: string | null;
  name: string | null;
  lastSeenAt: string;
};

function cleanString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizedAccount(
  input: RememberedSignInAccountInput,
  now: Date
): RememberedSignInAccount | null {
  const email = cleanString(input.email)?.toLowerCase() ?? null;
  const id = cleanString(input.id) ?? email;
  if (!id) return null;
  return {
    id,
    email,
    name: cleanString(input.name),
    lastSeenAt: now.toISOString(),
  };
}

export function parseRememberedSignInAccounts(
  raw: string | null | undefined
): RememberedSignInAccount[] {
  if (!raw) return [];
  try {
    const value = JSON.parse(raw) as unknown;
    if (!Array.isArray(value)) return [];
    return value
      .map((item): RememberedSignInAccount | null => {
        if (!item || typeof item !== "object") return null;
        const record = item as Record<string, unknown>;
        const id = cleanString(record.id);
        if (!id) return null;
        return {
          id,
          email: cleanString(record.email)?.toLowerCase() ?? null,
          name: cleanString(record.name),
          lastSeenAt: cleanString(record.lastSeenAt) ?? new Date(0).toISOString(),
        };
      })
      .filter((item): item is RememberedSignInAccount => item !== null)
      .sort((a, b) => b.lastSeenAt.localeCompare(a.lastSeenAt))
      .slice(0, RECENT_SIGN_IN_ACCOUNTS_MAX);
  } catch {
    return [];
  }
}

export function rememberSignInAccount(
  current: RememberedSignInAccount[],
  input: RememberedSignInAccountInput,
  now: Date = new Date()
): RememberedSignInAccount[] {
  const account = normalizedAccount(input, now);
  if (!account) return current.slice(0, RECENT_SIGN_IN_ACCOUNTS_MAX);
  const accountEmail = account.email?.toLowerCase() ?? null;
  const rest = current.filter((candidate) => {
    if (candidate.id === account.id) return false;
    if (accountEmail && candidate.email?.toLowerCase() === accountEmail) return false;
    return true;
  });
  return [account, ...rest].slice(0, RECENT_SIGN_IN_ACCOUNTS_MAX);
}

