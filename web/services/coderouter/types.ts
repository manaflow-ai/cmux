// Pinned coderouter wire contracts. Duplicated from workers/coderouter/src/types.ts;
// do not import across packages.
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

export type KeyPolicy = { allowedClasses?: CredentialClass[] };
