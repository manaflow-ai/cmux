export type CodeRouterProvider =
  | "codex"
  | "opencode-go"
  | "claude"
  | "anthropic-apikey"
  | "openai-apikey";

/** Every provider id the vault may store, in one place for CHECKs and parsers. */
export const CODEROUTER_PROVIDERS: readonly CodeRouterProvider[] = [
  "codex",
  "opencode-go",
  "claude",
  "anthropic-apikey",
  "openai-apikey",
];

/**
 * The account kinds each data plane can route over. The first entry is the
 * plane's own id: session bindings are keyed on it, so a session stays sticky
 * to one account no matter which kind it landed on.
 */
export const CLAUDE_PLANE_PROVIDERS: readonly CodeRouterProvider[] = ["claude", "anthropic-apikey"];
export const CODEX_PLANE_PROVIDERS: readonly CodeRouterProvider[] = ["codex", "openai-apikey"];

export type CodexCredential = {
  readonly provider: "codex";
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly idToken: string;
  /** The vault's dedupe identity: the ChatGPT account id, or a mirror id. */
  readonly accountId: string;
  /**
   * The ChatGPT account id sent upstream when `accountId` is not it (an
   * account mirrored from the app-side store keeps the app's id as identity).
   */
  readonly chatgptAccountId?: string;
  readonly email: string;
  readonly expiresAt: number;
};

/** The `chatgpt-account-id` the Codex backend expects for this credential. */
export function chatgptAccountId(credential: CodexCredential): string {
  return credential.chatgptAccountId ?? credential.accountId;
}

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

export type ClaudeCredential = {
  readonly provider: "claude";
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly accountId: string;
  readonly email: string;
  readonly subscriptionType?: string;
  readonly expiresAt: number;
};

/**
 * A long-lived provider API key. Nothing rotates: there is no refresh token
 * and no expiry, so a provider 401 means the key itself is dead.
 */
type ApiKeyCredentialBase = {
  readonly apiKey: string;
  /** Dedupe identity within the team (a hash of the key, or a mirror id). */
  readonly accountId: string;
  /** Display label; doubles as the vault's non-empty "email" slot. */
  readonly email: string;
};

export type AnthropicApiKeyCredential = ApiKeyCredentialBase & {
  readonly provider: "anthropic-apikey";
};

export type OpenAiApiKeyCredential = ApiKeyCredentialBase & {
  readonly provider: "openai-apikey";
};

export type ApiKeyCredential = AnthropicApiKeyCredential | OpenAiApiKeyCredential;

export type CodeRouterCredential =
  | CodexCredential
  | OpenCodeGoCredential
  | ClaudeCredential
  | ApiKeyCredential;

export function isApiKeyCredential(
  credential: CodeRouterCredential,
): credential is ApiKeyCredential {
  return credential.provider === "anthropic-apikey" || credential.provider === "openai-apikey";
}

/** Epoch ms the credential stops being usable; API keys never expire on their own. */
export function credentialExpiresAt(credential: CodeRouterCredential): number {
  return isApiKeyCredential(credential) ? Number.POSITIVE_INFINITY : credential.expiresAt;
}

/** The stored `credential_expires_at` column value: null for a key that never expires. */
export function credentialExpiryDate(credential: CodeRouterCredential): Date | null {
  return isApiKeyCredential(credential) ? null : new Date(credential.expiresAt);
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
