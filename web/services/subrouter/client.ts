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
};

export type ClaudeAccountInput = {
  readonly provider: "claude";
  readonly label?: string;
  readonly claudeAiOauth: Record<string, unknown> & {
    readonly accessToken: string;
    readonly refreshToken: string;
    readonly expiresAt: unknown;
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
  readonly tokens: Record<string, unknown> & {
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

export type SubrouterClient = {
  readonly createTenant: (input: { readonly name: string }) => Promise<SubrouterTenant>;
  readonly rotateTenant: (tenantId: string) => Promise<{ readonly id: string; readonly key: string }>;
  readonly revokeTenant: (tenantId: string) => Promise<void>;
  readonly listAccounts: (tenantKey: string) => Promise<readonly SubrouterAccount[]>;
  readonly createAccount: (
    tenantKey: string,
    input: SubrouterAccountInput,
    options?: { readonly validate?: boolean },
  ) => Promise<SubrouterAccount>;
  readonly deleteAccount: (tenantKey: string, accountId: string) => Promise<void>;
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
    createAccount: (tenantKey, input, createOptions = {}) => {
      const url = new URL(`${baseUrl}/tenant/accounts`);
      if (createOptions.validate) url.searchParams.set("validate", "1");
      return requestJson(
        fetchImpl,
        url.toString(),
        "createAccount",
        {
          method: "POST",
          headers: tenantHeaders(tenantKey),
          body: JSON.stringify(input),
        },
        parseAccount,
      );
    },
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
  if (!Array.isArray(value)) throw new SubrouterClientError("parseAccountList", null);
  return value.map(parseAccount);
}

function parseAccount(value: unknown): SubrouterAccount {
  if (!isRecord(value)) throw new SubrouterClientError("parseAccount", null);
  const { id, kind, label, createdAt } = value;
  if (typeof id !== "string" || typeof kind !== "string") {
    throw new SubrouterClientError("parseAccount", null);
  }
  if (label !== undefined && label !== null && typeof label !== "string") {
    throw new SubrouterClientError("parseAccount", null);
  }
  if (createdAt !== undefined && typeof createdAt !== "string") {
    throw new SubrouterClientError("parseAccount", null);
  }
  // Whitelist the browser-facing shape: never forward unknown upstream fields
  // across this trust boundary, even though the worker sanitizes accounts.
  return {
    id,
    kind,
    ...(label !== undefined ? { label } : {}),
    ...(createdAt !== undefined ? { createdAt } : {}),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
