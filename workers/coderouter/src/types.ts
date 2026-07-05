export type Family = "anthropic" | "openai";
export type EndpointClass = "anthropic" | "openai_api" | "codex";
export type CredentialKind = "oauth" | "api_key";
export type CredentialClass = "oauth" | "byok" | "managed";
export type CredentialStatus = "active" | "needs_reauth" | "disabled";

export interface PoolConfig {
  poolId: string;
  teamId: string;
  family: Family;
  configVersion: number;
  keys: {
    kid: string;
    revoked: boolean;
    policy: { allowedClasses?: CredentialClass[] };
  }[];
  credentials: {
    id: string;
    kind: CredentialKind;
    class: CredentialClass;
    status: CredentialStatus;
    label?: string;
    providerAccountId?: string;
    encryptedSecret?: string;
  }[];
  managed: { enabled: boolean };
  balanceMicros: number;
}

export interface SeedOauth {
  credentialId: string;
  provider: Family;
  accessToken: string;
  refreshToken: string;
  idToken?: string;
  accountId?: string;
  expiresAt?: number;
}

export interface UsageIngest {
  poolId: string;
  events: {
    eventId: string;
    keyId?: string;
    credentialId?: string;
    family: string;
    endpointClass: EndpointClass;
    model?: string;
    credentialClass: CredentialClass;
    status: number;
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheWriteTokens: number;
    estimated: boolean;
    costMicros?: number | null;
    latencyMs?: number;
    ts: number;
  }[];
  statusUpdates?: { credentialId: string; status: "active" | "needs_reauth" }[];
}

export interface VerifiedCallerKey {
  v: 1;
  kid: string;
  team: string;
  iat: number;
}

export interface Usage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  estimated: boolean;
}

export interface LimitWindow {
  name: string;
  usedPercent: number;
  limitWindowSeconds: number;
  resetAfterSeconds: number;
}

export interface CredentialLimitState {
  windows: LimitWindow[];
  cooldownUntil?: number;
  consecutive429?: number;
  consecutive401?: number;
  needsReauth?: boolean;
  lastPolledAt?: number;
}

export interface AcquireRequest {
  kid: string;
  teamId?: string;
  family: Family;
  endpointClass: EndpointClass;
  conversationKey: string;
  model?: string;
  estimate?: boolean;
  excludeCredentialIds?: string[];
}

export interface AcquireSuccess {
  ok: true;
  credentialId: string;
  class: CredentialClass;
  authHeaders: Record<string, string>;
  upstreamBase: string;
  accountId?: string;
}

export type AcquireErrorCode =
  | "key_revoked"
  | "config_unavailable"
  | "no_credentials"
  | "all_exhausted"
  | "insufficient_credits"
  | "model_not_priced";

export interface AcquireFailure {
  ok: false;
  error: AcquireErrorCode;
  soonestResetSeconds?: number;
}

export type AcquireResult = AcquireSuccess | AcquireFailure;

export interface ReportRequest {
  credentialId: string;
  kid: string;
  conversationKey: string;
  endpointClass: EndpointClass;
  model?: string;
  status: number;
  latencyMs: number;
  usage: Usage;
  rateLimitHeaders: Record<string, string>;
  usageLimited: boolean;
}
