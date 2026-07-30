export type SubrouterFetch = typeof fetch;

export type SubrouterRuntimeEnv = Record<string, string | undefined>;

export type SubrouterTenant = {
  readonly id: string;
  readonly name: string;
  readonly key: string;
};

export type SubrouterAccount = {
  readonly id: string;
  readonly kind: string;
  readonly label?: string | null;
  readonly createdAt?: string;
  readonly health?: {
    readonly ok: boolean;
    readonly message?: string;
  };
};

export type ClaudeAccountInput = {
  readonly provider: "claude";
  readonly label?: string;
  readonly claudeAiOauth: {
    readonly accessToken: string;
    readonly refreshToken: string;
    readonly expiresAt: number;
    readonly subscriptionType?: string;
    readonly rateLimitTier?: string;
  };
};

export type AnthropicApiKeyAccountInput = {
  readonly provider: "anthropic-apikey";
  readonly label?: string;
  readonly apiKey: string;
};

export type CodexAccountInput = {
  readonly provider: "codex";
  readonly label?: string;
  readonly tokens: {
    readonly accessToken: string;
    readonly refreshToken: string;
    readonly idToken: string;
    readonly accountID: string;
  };
};

export type OpenAiApiKeyAccountInput = {
  readonly provider: "openai-apikey";
  readonly label?: string;
  readonly apiKey: string;
};

export type SubrouterAccountInput =
  | ClaudeAccountInput
  | AnthropicApiKeyAccountInput
  | CodexAccountInput
  | OpenAiApiKeyAccountInput;

export type SubrouterCredentialLeaseInput = {
  readonly provider: "codex" | "claude";
  readonly agentType?: string;
  readonly sessionId: string;
  readonly userEmail?: string;
  readonly preferAccountId?: string;
  readonly model?: string;
  readonly requiredAuthMode?: "oauth" | "apikey";
};

export type SubrouterCredentialLease = {
  readonly leaseId: string;
  readonly accountId: string;
  readonly provider: "codex" | "claude";
  readonly authMode: "oauth" | "apikey";
  readonly token: string;
  readonly providerAccountId?: string;
  readonly label: string;
  readonly email?: string;
  readonly credentialGeneration: number;
  readonly issuedAt: string;
  readonly expiresAt: string;
  readonly credentialExpiresAt?: string;
};

export type SubrouterCredentialLeaseOutcome =
  | "success"
  | "unauthorized"
  | "rate_limited"
  | "provider_error";

export type SubrouterClient = {
  readonly createTenant: (input: { readonly name: string }) => Promise<SubrouterTenant>;
  readonly rotateTenant: (tenantId: string) => Promise<{ readonly id: string; readonly key: string }>;
  readonly revokeTenant: (tenantId: string) => Promise<void>;
  readonly listAccounts: (tenantKey: string) => Promise<readonly SubrouterAccount[]>;
  readonly createAccount: (
    tenantKey: string,
    input: SubrouterAccountInput,
  ) => Promise<SubrouterAccount>;
  readonly deleteAccount: (tenantKey: string, accountId: string) => Promise<void>;
  readonly repairAccount: (
    tenantKey: string,
    accountId: string,
    input: SubrouterAccountInput,
  ) => Promise<SubrouterAccount>;
  readonly createCredentialLease: (
    tenantKey: string,
    input: SubrouterCredentialLeaseInput,
  ) => Promise<SubrouterCredentialLease>;
  readonly reportCredentialLease: (
    tenantKey: string,
    leaseId: string,
    input: {
      readonly outcome: SubrouterCredentialLeaseOutcome;
      readonly statusCode?: number;
    },
  ) => Promise<{ readonly ok: true; readonly refreshState?: "refreshed" }>;
};

export type SubrouterRuntimeConfig = {
  readonly baseUrl: string;
  readonly adminToken: string;
  readonly tenantKeySecret: string;
};

export class SubrouterNotConfiguredError extends Error {
  constructor() {
    super("subrouter not configured");
    this.name = "SubrouterNotConfiguredError";
  }
}

export class SubrouterClientError extends Error {
  readonly operation: string;
  readonly status: number | null;

  constructor(operation: string, status: number | null) {
    super("subrouter request failed");
    this.name = "SubrouterClientError";
    this.operation = operation;
    this.status = status;
  }
}

export function subrouterRuntimeConfig(
  env: SubrouterRuntimeEnv = process.env,
): SubrouterRuntimeConfig | null {
  const adminToken = trimEnv(env.SUBROUTER_ADMIN_TOKEN);
  const tenantKeySecret = trimEnv(env.SUBROUTER_TENANT_KEY_SECRET);
  if (!adminToken || !tenantKeySecret) return null;

  return {
    baseUrl: trimEnv(env.SUBROUTER_BASE_URL) ?? defaultSubrouterBaseUrl(env),
    adminToken,
    tenantKeySecret,
  };
}

export function isSubrouterConfigured(env: SubrouterRuntimeEnv = process.env): boolean {
  return subrouterRuntimeConfig(env) !== null;
}

export function createSubrouterClientFromEnv(options: {
  readonly fetch?: SubrouterFetch;
  readonly env?: SubrouterRuntimeEnv;
} = {}): SubrouterClient {
  const config = subrouterRuntimeConfig(options.env);
  if (!config) throw new SubrouterNotConfiguredError();
  return createSubrouterClient({
    baseUrl: config.baseUrl,
    adminToken: config.adminToken,
    fetch: options.fetch,
  });
}

export function createSubrouterClient(options: {
  readonly baseUrl: string;
  readonly adminToken: string;
  readonly fetch?: SubrouterFetch;
}): SubrouterClient {
  const baseUrl = options.baseUrl.replace(/\/+$/, "");
  const fetchImpl = options.fetch ?? fetch;
  const adminToken = options.adminToken;

  return {
    createTenant: (input) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/admin/tenants`,
        "createTenant",
        {
          method: "POST",
          headers: adminHeaders(adminToken),
          body: JSON.stringify({ name: input.name }),
        },
        parseTenant,
      ),
    rotateTenant: (tenantId) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/admin/tenants/${encodeURIComponent(tenantId)}/rotate`,
        "rotateTenant",
        {
          method: "POST",
          headers: adminHeaders(adminToken),
        },
        parseTenantRotation,
      ),
    revokeTenant: async (tenantId) => {
      await requestNoBody(fetchImpl, `${baseUrl}/admin/tenants/${encodeURIComponent(tenantId)}/revoke`, "revokeTenant", {
        method: "POST",
        headers: adminHeaders(adminToken),
      });
    },
    listAccounts: (tenantKey) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/tenant/accounts`,
        "listAccounts",
        {
          method: "GET",
          headers: tenantHeaders(tenantKey),
        },
        parseAccountList,
      ),
    createAccount: (tenantKey, input) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/tenant/accounts?adopt=1&validate=1`,
        "createAccount",
        {
          method: "POST",
          headers: tenantHeaders(tenantKey),
          body: JSON.stringify(input),
        },
        parseAccount,
      ),
    deleteAccount: async (tenantKey, accountId) => {
      await requestNoBody(
        fetchImpl,
        `${baseUrl}/tenant/accounts/${encodeURIComponent(accountId)}`,
        "deleteAccount",
        {
          method: "DELETE",
          headers: tenantHeaders(tenantKey),
        },
      );
    },
    repairAccount: (tenantKey, accountId, input) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/tenant/accounts/${encodeURIComponent(accountId)}/repair?adopt=1&validate=1`,
        "repairAccount",
        {
          method: "POST",
          headers: tenantHeaders(tenantKey),
          body: JSON.stringify(input),
        },
        parseAccount,
      ),
    createCredentialLease: (tenantKey, input) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/tenant/leases`,
        "createCredentialLease",
        {
          method: "POST",
          headers: tenantHeaders(tenantKey),
          body: JSON.stringify(input),
        },
        parseCredentialLease,
      ),
    reportCredentialLease: (tenantKey, leaseId, input) =>
      requestJson(
        fetchImpl,
        `${baseUrl}/tenant/leases/${encodeURIComponent(leaseId)}/events`,
        "reportCredentialLease",
        {
          method: "POST",
          headers: tenantHeaders(tenantKey),
          body: JSON.stringify(input),
        },
        parseCredentialLeaseReport,
      ),
  };
}

function defaultSubrouterBaseUrl(env: SubrouterRuntimeEnv): string {
  return env.VERCEL_ENV === "production"
    ? "https://subrouter.cmux.dev"
    : "https://subrouter-staging.cmux.dev";
}

function trimEnv(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function adminHeaders(adminToken: string): HeadersInit {
  return {
    authorization: `Bearer ${adminToken}`,
    "content-type": "application/json",
  };
}

function tenantHeaders(tenantKey: string): HeadersInit {
  return {
    authorization: `Bearer ${tenantKey}`,
    "content-type": "application/json",
  };
}

async function requestJson<T>(
  fetchImpl: SubrouterFetch,
  url: string,
  operation: string,
  init: RequestInit,
  parse: (value: unknown) => T,
): Promise<T> {
  const response = await subrouterFetch(fetchImpl, url, operation, init);
  let parsed: unknown;
  try {
    parsed = await response.json();
  } catch {
    throw new SubrouterClientError(operation, response.status);
  }
  return parse(parsed);
}

async function requestNoBody(
  fetchImpl: SubrouterFetch,
  url: string,
  operation: string,
  init: RequestInit,
): Promise<void> {
  await subrouterFetch(fetchImpl, url, operation, init);
}

async function subrouterFetch(
  fetchImpl: SubrouterFetch,
  url: string,
  operation: string,
  init: RequestInit,
): Promise<Response> {
  let response: Response;
  try {
    response = await fetchImpl(url, {
      ...init,
      signal: init.signal ?? AbortSignal.timeout(10_000),
    });
  } catch {
    throw new SubrouterClientError(operation, null);
  }
  if (!response.ok) {
    throw new SubrouterClientError(operation, response.status);
  }
  return response;
}

function parseTenant(value: unknown): SubrouterTenant {
  if (!isRecord(value)) throw new SubrouterClientError("parseTenant", null);
  const { id, name, key } = value;
  if (typeof id !== "string" || typeof name !== "string" || typeof key !== "string") {
    throw new SubrouterClientError("parseTenant", null);
  }
  return { id, name, key };
}

function parseTenantRotation(value: unknown): { readonly id: string; readonly key: string } {
  if (!isRecord(value)) throw new SubrouterClientError("parseTenantRotation", null);
  const { id, key } = value;
  if (typeof id !== "string" || typeof key !== "string") {
    throw new SubrouterClientError("parseTenantRotation", null);
  }
  return { id, key };
}

function parseAccountList(value: unknown): readonly SubrouterAccount[] {
  const accounts = Array.isArray(value)
    ? value
    : isRecord(value) && Array.isArray(value.accounts)
      ? value.accounts
      : null;
  if (!accounts) throw new SubrouterClientError("parseAccountList", null);
  return accounts.map(parseAccount);
}

function parseAccount(value: unknown): SubrouterAccount {
  if (!isRecord(value)) throw new SubrouterClientError("parseAccount", null);
  const { id, label } = value;
  const createdAt = value.createdAt ?? value.created_at;
  const kind = typeof value.kind === "string"
    ? value.kind
    : accountKindFromProvider(value.provider, value.auth_mode);
  if (typeof id !== "string" || !kind) {
    throw new SubrouterClientError("parseAccount", null);
  }
  if (label !== undefined && label !== null && typeof label !== "string") {
    throw new SubrouterClientError("parseAccount", null);
  }
  if (createdAt !== undefined && typeof createdAt !== "string") {
    throw new SubrouterClientError("parseAccount", null);
  }
  const health = parseAccountHealth(value.health);
  // Whitelist the browser-facing shape: never forward unknown upstream fields
  // across this trust boundary, even though the worker sanitizes accounts.
  return {
    id,
    kind,
    ...(label !== undefined ? { label } : {}),
    ...(createdAt !== undefined ? { createdAt } : {}),
    ...(health ? { health } : {}),
  };
}

function parseAccountHealth(
  value: unknown,
): { readonly ok: boolean; readonly message?: string } | undefined {
  if (value === undefined || value === null) return undefined;
  if (!isRecord(value) || typeof value.ok !== "boolean") {
    throw new SubrouterClientError("parseAccountHealth", null);
  }
  if (value.message !== undefined && typeof value.message !== "string") {
    throw new SubrouterClientError("parseAccountHealth", null);
  }
  return {
    ok: value.ok,
    ...(typeof value.message === "string" ? { message: value.message } : {}),
  };
}

function accountKindFromProvider(provider: unknown, authMode: unknown): string | null {
  if (provider === "codex" && authMode === "oauth") return "codex";
  if (provider === "codex" && authMode === "apikey") return "openai-apikey";
  if (provider === "claude" && authMode === "oauth") return "claude";
  if (provider === "claude" && authMode === "apikey") return "anthropic-apikey";
  return null;
}

function parseCredentialLease(value: unknown): SubrouterCredentialLease {
  if (!isRecord(value)) {
    throw new SubrouterClientError("parseCredentialLease", null);
  }
  const {
    leaseId,
    accountId,
    provider,
    authMode,
    token,
    providerAccountId,
    label,
    email,
    credentialGeneration,
    issuedAt,
    expiresAt,
    credentialExpiresAt,
  } = value;
  if (
    typeof leaseId !== "string" ||
    typeof accountId !== "string" ||
    (provider !== "codex" && provider !== "claude") ||
    (authMode !== "oauth" && authMode !== "apikey") ||
    typeof token !== "string" ||
    typeof label !== "string" ||
    typeof credentialGeneration !== "number" ||
    typeof issuedAt !== "string" ||
    typeof expiresAt !== "string"
  ) {
    throw new SubrouterClientError("parseCredentialLease", null);
  }
  if (providerAccountId !== undefined && typeof providerAccountId !== "string") {
    throw new SubrouterClientError("parseCredentialLease", null);
  }
  if (email !== undefined && typeof email !== "string") {
    throw new SubrouterClientError("parseCredentialLease", null);
  }
  if (credentialExpiresAt !== undefined && typeof credentialExpiresAt !== "string") {
    throw new SubrouterClientError("parseCredentialLease", null);
  }
  return {
    leaseId,
    accountId,
    provider,
    authMode,
    token,
    ...(providerAccountId ? { providerAccountId } : {}),
    label,
    ...(email ? { email } : {}),
    credentialGeneration,
    issuedAt,
    expiresAt,
    ...(credentialExpiresAt ? { credentialExpiresAt } : {}),
  };
}

function parseCredentialLeaseReport(
  value: unknown,
): { readonly ok: true; readonly refreshState?: "refreshed" } {
  if (!isRecord(value) || value.ok !== true) {
    throw new SubrouterClientError("parseCredentialLeaseReport", null);
  }
  const refreshState = value.refreshState;
  if (refreshState !== undefined && refreshState !== "refreshed") {
    throw new SubrouterClientError("parseCredentialLeaseReport", null);
  }
  return {
    ok: true,
    ...(refreshState ? { refreshState } : {}),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
