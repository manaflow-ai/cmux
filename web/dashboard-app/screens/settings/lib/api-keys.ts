const DAY_MS = 1000 * 60 * 60 * 24;

/** Hexclave encodes "never" as 200 years; the server stores a real date. */
export const NEVER_EXPIRES_MS = DAY_MS * 365 * 200;

export const API_KEY_EXPIRY_OPTIONS = ["1d", "7d", "30d", "90d", "1y", "never"] as const;
export type ApiKeyExpiryOption = (typeof API_KEY_EXPIRY_OPTIONS)[number];
export const DEFAULT_API_KEY_EXPIRY: ApiKeyExpiryOption = "30d";

const EXPIRY_MS: Record<ApiKeyExpiryOption, number> = {
  "1d": DAY_MS,
  "7d": DAY_MS * 7,
  "30d": DAY_MS * 30,
  "90d": DAY_MS * 90,
  "1y": DAY_MS * 365,
  never: NEVER_EXPIRES_MS,
};

export function isApiKeyExpiryOption(value: string): value is ApiKeyExpiryOption {
  return (API_KEY_EXPIRY_OPTIONS as readonly string[]).includes(value);
}

/** The `expiresAt` passed to `createApiKey` for an expiry choice. */
export function apiKeyExpiresAt(option: ApiKeyExpiryOption, now: number = Date.now()): Date {
  return new Date(now + EXPIRY_MS[option]);
}

/**
 * Dates more than 50 years out render as "Never", matching Hexclave's
 * `DateCell ignoreAfterYears={50}`.
 */
export function isEffectivelyNever(date: Date | undefined, now: number = Date.now()): boolean {
  return !date || date.getTime() - now > DAY_MS * 365 * 50;
}

export type ApiKeyStatus = "valid" | "expired" | "revoked";
export const API_KEY_STATUSES: readonly ApiKeyStatus[] = ["valid", "expired", "revoked"];

export type ApiKeyFacts = {
  readonly description: string;
  readonly createdAt: Date;
  readonly value: { readonly lastFour: string };
  whyInvalid(): "manually-revoked" | "expired" | null;
};

export function apiKeyStatus(key: Pick<ApiKeyFacts, "whyInvalid">): ApiKeyStatus {
  const reason = key.whyInvalid();
  if (reason === "manually-revoked") return "revoked";
  if (reason === "expired") return "expired";
  return "valid";
}

/** Valid keys first, then newest first. */
export function sortApiKeys<T extends ApiKeyFacts>(keys: readonly T[]): T[] {
  return [...keys].sort((a, b) => {
    const aValid = apiKeyStatus(a) === "valid";
    const bValid = apiKeyStatus(b) === "valid";
    if (aValid !== bValid) return aValid ? -1 : 1;
    return b.createdAt.getTime() - a.createdAt.getTime();
  });
}

/**
 * Filter by free-text search (description or last four characters) and by
 * status. An empty status set means every status.
 */
export function filterApiKeys<T extends ApiKeyFacts>(
  keys: readonly T[],
  search: string,
  statuses: ReadonlySet<ApiKeyStatus>,
): T[] {
  const query = search.trim().toLowerCase();
  return keys.filter((key) => {
    if (statuses.size > 0 && !statuses.has(apiKeyStatus(key))) return false;
    if (!query) return true;
    return (
      key.description.toLowerCase().includes(query) ||
      key.value.lastFour.toLowerCase().includes(query)
    );
  });
}
