export type CodeRouterProvider =
  | "codex"
  | "opencode-go"
  | "openai-apikey"
  | "openrouter-apikey";

/** Every provider a coderouter account row may carry. Mirrors the DB CHECK. */
export const CODEROUTER_PROVIDERS: readonly CodeRouterProvider[] = [
  "codex",
  "opencode-go",
  "openai-apikey",
  "openrouter-apikey",
];

/** Providers whose credentials are OAuth tokens that expire and refresh. */
export type CodeRouterOAuthProvider = "codex" | "opencode-go";

/** Providers whose credential is one long-lived API key. */
export type CodeRouterApiKeyProvider = "openai-apikey" | "openrouter-apikey";

export const CODEROUTER_API_KEY_PROVIDERS: readonly CodeRouterApiKeyProvider[] = [
  "openai-apikey",
  "openrouter-apikey",
];

/** Every provider that can serve the OpenAI Responses surface (`/v1/responses`, `/v1/models`). */
export const RESPONSES_PROVIDERS: readonly CodeRouterProvider[] = [
  "codex",
  "openai-apikey",
  "openrouter-apikey",
];

export type CodexCredential = {
  readonly provider: "codex";
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly idToken: string;
  readonly accountId: string;
  readonly email: string;
  readonly expiresAt: number;
};

export type OpenCodeGoCredential = {
  readonly provider: "opencode-go";
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly accountId: string;
  readonly email: string;
  readonly orgId?: string;
  readonly orgName?: string;
  readonly expiresAt: number;
};

/**
 * A pasted OpenAI or OpenRouter API key. `accountId` is a fingerprint of the
 * key, so the same key added twice is one account and the row never carries
 * the key itself. `label` is what the dashboard shows; the masked key is the
 * fallback. API keys have no expiry, so there is no refresh token.
 */
export type ApiKeyCredential = {
  readonly provider: CodeRouterApiKeyProvider;
  readonly apiKey: string;
  readonly accountId: string;
  readonly label: string;
};

export type OAuthCredential = CodexCredential | OpenCodeGoCredential;

export type CodeRouterCredential = OAuthCredential | ApiKeyCredential;

export function isApiKeyCredential(
  credential: CodeRouterCredential,
): credential is ApiKeyCredential {
  return credential.provider === "openai-apikey" || credential.provider === "openrouter-apikey";
}

export function isApiKeyProvider(
  provider: CodeRouterProvider,
): provider is CodeRouterApiKeyProvider {
  return provider === "openai-apikey" || provider === "openrouter-apikey";
}

/** When the stored credential stops working on its own. API keys never do. */
export function credentialExpiresAt(credential: CodeRouterCredential): Date | null {
  return isApiKeyCredential(credential) ? null : new Date(credential.expiresAt);
}

/** The dashboard name for an account: the sign-in email, org, label, or a masked key. */
export function credentialLabel(credential: CodeRouterCredential): string {
  if (isApiKeyCredential(credential)) {
    return credential.label || maskApiKey(credential.apiKey);
  }
  return credential.email ||
    (credential.provider === "opencode-go" ? credential.orgName : undefined) ||
    credential.accountId;
}

/** `sk-or-v1-…a1b2`: enough to tell keys apart, never enough to use one. */
export function maskApiKey(apiKey: string): string {
  const trimmed = apiKey.trim();
  if (trimmed.length <= 12) return "…";
  const prefixEnd = trimmed.lastIndexOf("-", 12);
  const prefix = prefixEnd > 0 ? trimmed.slice(0, prefixEnd + 1) : trimmed.slice(0, 5);
  return `${prefix}…${trimmed.slice(-4)}`;
}

export type VaultAccount = {
  readonly revision: number;
  readonly credential: CodeRouterCredential;
};

export type CodeRouterVault = {
  readonly version: 1;
  readonly accounts: Readonly<Record<string, VaultAccount>>;
};

export type CodeRouterAccountSummary = {
  readonly id: string;
  readonly provider: CodeRouterProvider;
  readonly providerAccountId: string;
  readonly label: string;
  readonly state: "active" | "refreshing" | "expired" | "broken";
  readonly credentialExpiresAt: string | null;
  readonly lastFailureCode: string | null;
  readonly cooldownUntil: string | null;
  /** Sessions bound to this account with traffic in the recent window. */
  readonly activeSessions: number;
};
