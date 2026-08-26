import { env } from "../../app/env";
import {
  defaultHostedSubrouterURL,
  hostedSubrouterBaseURL,
} from "./constants";
import type {
  SubrouterAccount,
  SubrouterAccountInput,
  SubrouterCredentialLease,
  SubrouterCredentialLeaseInput,
  SubrouterCredentialLeaseOutcome,
} from "./types";

export type HostedTenant = {
  readonly tenantId: string;
  readonly tenantName: string;
  readonly tenantKey: string;
  readonly proxyUrl: string;
  readonly capabilities: readonly HostedTenantCapability[];
};

export type HostedTenantCapability = "use" | "manage_accounts";

export type HostedTeam = {
  readonly teamId: string;
  readonly teamName: string;
  readonly use: boolean;
  readonly manageAccounts: boolean;
};

export type HostedSubrouterClient = {
  readonly tenantControlConfigured: boolean;
  readonly assertTenantDeletionConfigured: () => void;
  readonly exchangeTeam: (
    accessToken: string,
    team: HostedTeam,
  ) => Promise<HostedTenant>;
  readonly deleteTenant: (
    accessToken: string,
    teamId: string,
    options?: { readonly signal?: AbortSignal },
  ) => Promise<void>;
  readonly listAccounts: (tenantKey: string) => Promise<readonly SubrouterAccount[]>;
  readonly createAccount: (
    tenantKey: string,
    input: SubrouterAccountInput,
  ) => Promise<SubrouterAccount>;
  readonly repairAccount: (
    tenantKey: string,
    accountId: string,
    input: SubrouterAccountInput,
  ) => Promise<SubrouterAccount>;
  readonly deleteAccount: (tenantKey: string, accountId: string) => Promise<void>;
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

export function createHostedSubrouterClient(options: {
  readonly baseUrl?: string;
  readonly tenantDeleteToken?: string;
  readonly fetch?: typeof fetch;
} = {}): HostedSubrouterClient {
  const baseUrl = hostedSubrouterBaseURL(
    options.baseUrl ?? env.SUBROUTER_HOSTED_URL ?? defaultHostedSubrouterURL(),
  );
  const fetchImpl = options.fetch ?? fetch;
  // Read lazily from process.env, not the validated `env` object: t3-env
  // freezes values at first import, but tenant-control configuration must be
  // observable per client construction (env.ts still validates presence on
  // Vercel non-preview deployments).
  const tenantDeleteToken = (
    options.tenantDeleteToken ??
    process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN ??
    ""
  ).trim();
  const assertTenantControlConfigured = (): void => {
    if (!tenantDeleteToken) {
      throw new HostedSubrouterError(
        "hosted Subrouter tenant control is not configured",
        503,
      );
    }
  };

  const tenantRequest = (
    tenantKey: string,
    path: string,
    init: RequestInit,
  ): Promise<unknown> => {
    const headers = new Headers(init.headers);
    headers.set("authorization", `Bearer ${tenantKey}`);
    return requestJson(fetchImpl, `${baseUrl}${path}`, { ...init, headers });
  };
  const tenantRequestResponse = (
    tenantKey: string,
    path: string,
    init: RequestInit,
  ): Promise<Response> => {
    const headers = new Headers(init.headers);
    headers.set("authorization", `Bearer ${tenantKey}`);
    return requestResponse(fetchImpl, `${baseUrl}${path}`, { ...init, headers });
  };
  const tenantRequestWithoutResponse = async (
    tenantKey: string,
    path: string,
    init: RequestInit,
  ): Promise<void> => {
    await tenantRequestResponse(tenantKey, path, init);
  };
  const uploadAccount = async (
    tenantKey: string,
    input: SubrouterAccountInput,
    targetAccountID?: string,
  ): Promise<SubrouterAccount> => {
    const response = await tenantRequest(
      tenantKey,
      "/_subrouter/accounts",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          ...input,
          ...(targetAccountID ? { targetAccountID } : {}),
        }),
      },
    );
    if (!isRecord(response) || !isRecord(response.account)) {
      throw new HostedSubrouterError("invalid account response", 502);
    }
    return parseAccountEnvelope(response.account);
  };

  return {
    tenantControlConfigured: tenantDeleteToken.length > 0,
    assertTenantDeletionConfigured: assertTenantControlConfigured,
    exchangeTeam: async (accessToken, team) => {
      assertTenantControlConfigured();
      const capabilities = hostedTenantCapabilities(team);
      if (capabilities.length === 0) {
        throw new HostedSubrouterError(
          "hosted Subrouter team has no capabilities",
          403,
          "caller",
        );
      }
      const response = await requestJson(
        fetchImpl,
        `${baseUrl}/_subrouter/auth/stack`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${accessToken}`,
            "content-type": "application/json",
            "x-subrouter-stack-control-token": tenantDeleteToken,
          },
          body: JSON.stringify({
            capabilities,
            teamId: team.teamId,
            teamName: team.teamName,
          }),
        },
        "caller",
      );
      const tenant = parseHostedTenant(response);
      if (tenant.tenantId !== team.teamId) {
        throw new HostedSubrouterError(
          "hosted Subrouter returned a tenant for a different team",
          502,
        );
      }
      if (!sameCapabilities(tenant.capabilities, capabilities)) {
        throw new HostedSubrouterError(
          "hosted Subrouter returned mismatched capabilities",
          502,
        );
      }
      return tenant;
    },
    deleteTenant: async (accessToken, teamId, options) => {
      assertTenantControlConfigured();
      const upstreamResponse = await requestResponse(
        fetchImpl,
        `${baseUrl}/_subrouter/auth/stack/tenant`,
        {
          method: "DELETE",
          headers: {
            authorization: `Bearer ${accessToken}`,
            "content-type": "application/json",
            "x-subrouter-tenant-delete-token": tenantDeleteToken,
          },
          body: JSON.stringify({ teamId }),
          signal: options?.signal,
        },
      );
      const response = await responseJson(upstreamResponse);
      if (!isRecord(response)) {
        throw new HostedSubrouterError("invalid tenant deletion response", 502);
      }
      if (response.deletionPending === true) {
        throw new HostedSubrouterError(
          "hosted Subrouter tenant deletion is pending",
          503,
        );
      }
      if (
        upstreamResponse.status !== 200 ||
        response.ok !== true ||
        typeof response.deleted !== "boolean" ||
        "deletionPending" in response
      ) {
        throw new HostedSubrouterError("invalid tenant deletion response", 502);
      }
    },
    listAccounts: async (tenantKey) => {
      const response = await tenantRequest(
        tenantKey,
        "/_subrouter/accounts",
        { method: "GET" },
      );
      if (!Array.isArray(response)) throw new HostedSubrouterError("invalid account list", 502);
      return response.map(parseHostedAccount);
    },
    createAccount: async (tenantKey, input) =>
      await uploadAccount(tenantKey, input),
    repairAccount: async (tenantKey, accountId, input) =>
      await uploadAccount(tenantKey, input, accountId),
    deleteAccount: async (tenantKey, accountId) => {
      await tenantRequestWithoutResponse(
        tenantKey,
        `/_subrouter/accounts/${encodeURIComponent(accountId)}`,
        { method: "DELETE" },
      );
    },
    createCredentialLease: async (tenantKey, input) => {
      const response = await tenantRequest(
        tenantKey,
        "/_subrouter/leases",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(input),
        },
      );
      if (!isRecord(response) || !isRecord(response.lease)) {
        throw new HostedSubrouterError("invalid credential lease", 502);
      }
      return parseCredentialLease(response.lease);
    },
    reportCredentialLease: async (tenantKey, leaseId, input) => {
      const response = await tenantRequestResponse(
        tenantKey,
        `/_subrouter/leases/${encodeURIComponent(leaseId)}/events`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(input),
        },
      );
      if (response.status === 204) return { ok: true };
      const body = await responseJson(response);
      if (
        !isRecord(body) ||
        body.ok !== true ||
        (body.refreshState !== undefined && body.refreshState !== "refreshed")
      ) {
        throw new HostedSubrouterError("invalid credential lease report", 502);
      }
      return {
        ok: true,
        ...(body.refreshState === "refreshed"
          ? { refreshState: "refreshed" as const }
          : {}),
      };
    },
  };
}

export class HostedSubrouterError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly authentication: "caller" | "internal" = "internal",
  ) {
    super(message);
    this.name = "HostedSubrouterError";
  }
}

async function requestJson(
  fetchImpl: typeof fetch,
  url: string,
  init: RequestInit,
  authentication: "caller" | "internal" = "internal",
): Promise<unknown> {
  const response = await requestResponse(
    fetchImpl,
    url,
    init,
    authentication,
  );
  return await responseJson(response);
}

async function responseJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new HostedSubrouterError("hosted Subrouter returned invalid JSON", 502);
  }
}

async function requestResponse(
  fetchImpl: typeof fetch,
  url: string,
  init: RequestInit,
  authentication: "caller" | "internal" = "internal",
): Promise<Response> {
  let response: Response;
  try {
    response = await fetchImpl(url, {
      ...init,
      signal: init.signal ?? AbortSignal.timeout(10_000),
    });
  } catch {
    throw new HostedSubrouterError("hosted Subrouter unavailable", 503);
  }
  if (!response.ok) {
    throw new HostedSubrouterError(
      "hosted Subrouter request failed",
      response.status,
      authentication,
    );
  }
  return response;
}

function parseHostedTenant(value: unknown): HostedTenant {
  if (
    !isRecord(value) ||
    !isString(value.tenantId) ||
    !isString(value.tenantName) ||
    !isString(value.tenantKey) ||
    !isString(value.proxyUrl) ||
    !Array.isArray(value.capabilities) ||
    !value.capabilities.every(isHostedTenantCapability)
  ) {
    throw new HostedSubrouterError("invalid hosted tenant response", 502);
  }
  return {
    tenantId: value.tenantId,
    tenantName: value.tenantName,
    tenantKey: value.tenantKey,
    proxyUrl: value.proxyUrl,
    capabilities: value.capabilities,
  };
}

function hostedTenantCapabilities(
  team: Pick<HostedTeam, "use" | "manageAccounts">,
): HostedTenantCapability[] {
  return [
    ...(team.use ? ["use" as const] : []),
    ...(team.manageAccounts ? ["manage_accounts" as const] : []),
  ];
}

function isHostedTenantCapability(
  value: unknown,
): value is HostedTenantCapability {
  return value === "use" || value === "manage_accounts";
}

function sameCapabilities(
  left: readonly HostedTenantCapability[],
  right: readonly HostedTenantCapability[],
): boolean {
  const leftSet = new Set(left);
  const rightSet = new Set(right);
  return leftSet.size === left.length &&
    rightSet.size === right.length &&
    leftSet.size === rightSet.size &&
    [...leftSet].every((capability) => rightSet.has(capability));
}

function parseHostedAccount(value: unknown): SubrouterAccount {
  if (!isRecord(value) || !isString(value.id) || !isString(value.provider)) {
    throw new HostedSubrouterError("invalid hosted account", 502);
  }
  const explicitLabel = value.label;
  const createdAt = value.createdAt ?? value.created_at;
  if (
    (explicitLabel !== undefined &&
      explicitLabel !== null &&
      typeof explicitLabel !== "string") ||
    (createdAt !== undefined && typeof createdAt !== "string")
  ) {
    throw new HostedSubrouterError("invalid hosted account", 502);
  }
  const kind = accountKindFromProvider(value.provider, value.auth_mode);
  if (!kind) {
    throw new HostedSubrouterError("invalid hosted account", 502);
  }
  const fallbackLabel = isString(value.email) ? value.email : value.id;
  const apiKeyPrefix = `apikey:${kind}:`;
  const label = explicitLabel !== undefined
    ? explicitLabel
    : fallbackLabel.startsWith(apiKeyPrefix)
    ? fallbackLabel.slice(apiKeyPrefix.length)
    : fallbackLabel;
  return {
    id: value.id,
    kind,
    label,
    ...(createdAt !== undefined ? { createdAt } : {}),
    ...parseHealth(value.health),
  };
}

function accountKindFromProvider(
  provider: unknown,
  authMode: unknown,
): SubrouterAccount["kind"] | null {
  if (provider === "codex" && authMode === "oauth") return "codex";
  if (provider === "codex" && authMode === "apikey") return "openai-apikey";
  if (provider === "claude" && authMode === "oauth") return "claude";
  if (provider === "claude" && authMode === "apikey") return "anthropic-apikey";
  return null;
}

function parseAccountEnvelope(value: Record<string, unknown>): SubrouterAccount {
  if (!isString(value.id) || !isString(value.kind)) {
    throw new HostedSubrouterError("invalid hosted account", 502);
  }
  return {
    id: value.id,
    kind: value.kind,
    label: isString(value.label) ? value.label : undefined,
    ...parseHealth(value.health),
  };
}

function parseCredentialLease(value: unknown): SubrouterCredentialLease {
  if (!isRecord(value)) {
    throw new HostedSubrouterError("invalid credential lease", 502);
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
    !isString(leaseId) ||
    !isString(accountId) ||
    (provider !== "codex" && provider !== "claude") ||
    (authMode !== "oauth" && authMode !== "apikey") ||
    !isString(token) ||
    !isString(label) ||
    typeof credentialGeneration !== "number" ||
    !isString(issuedAt) ||
    !isString(expiresAt) ||
    (providerAccountId !== undefined && typeof providerAccountId !== "string") ||
    (email !== undefined && typeof email !== "string") ||
    (credentialExpiresAt !== undefined && typeof credentialExpiresAt !== "string")
  ) {
    throw new HostedSubrouterError("invalid credential lease", 502);
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

function parseHealth(
  value: unknown,
): Pick<SubrouterAccount, "health"> {
  if (!isRecord(value) || typeof value.ok !== "boolean") return {};
  return {
    health: {
      ok: value.ok,
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
