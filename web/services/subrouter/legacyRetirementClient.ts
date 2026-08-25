export type LegacySubrouterRuntimeEnv = Record<string, string | undefined>;

export type LegacySubrouterRetirementConfig = {
  readonly baseUrl: string;
  readonly adminToken: string;
};

export type LegacySubrouterMigrationInput = {
  readonly destinationUrl: string;
  readonly tenantKey: string;
  readonly finalizeSource: boolean;
};

export type LegacySubrouterRetirementClient = {
  readonly revokeTenant: (
    tenantId: string,
    options?: { readonly signal?: AbortSignal },
  ) => Promise<{ readonly revoked: boolean }>;
  readonly migrateTenant: (
    tenantId: string,
    input: LegacySubrouterMigrationInput,
  ) => Promise<{
    readonly migrated: number;
    readonly sourceFinalized: boolean;
  }>;
};

export class LegacySubrouterRetirementError extends Error {
  constructor(
    readonly operation: "revoke" | "migrate",
    readonly status: number | null,
  ) {
    super(`legacy Subrouter ${operation} failed`);
    this.name = "LegacySubrouterRetirementError";
  }
}

export function legacySubrouterRetirementConfig(
  runtimeEnv: LegacySubrouterRuntimeEnv = process.env,
): LegacySubrouterRetirementConfig {
  const adminToken = runtimeEnv.SUBROUTER_ADMIN_TOKEN?.trim();
  if (!adminToken) {
    throw new Error("legacy Subrouter retirement is not configured");
  }
  const baseUrl = (
    runtimeEnv.SUBROUTER_BASE_URL?.trim() ||
    (runtimeEnv.VERCEL_ENV === "production"
      ? "https://subrouter.cmux.dev"
      : "https://subrouter-staging.cmux.dev")
  ).replace(/\/+$/, "");
  assertSafeBaseUrl(baseUrl);
  return { baseUrl, adminToken };
}

export function createLegacySubrouterRetirementClient(
  options: LegacySubrouterRetirementConfig & {
    readonly fetch?: typeof fetch;
  },
): LegacySubrouterRetirementClient {
  const baseUrl = options.baseUrl.replace(/\/+$/, "");
  assertSafeBaseUrl(baseUrl);
  const adminToken = options.adminToken.trim();
  if (!adminToken) {
    throw new Error("legacy Subrouter retirement is not configured");
  }
  const fetchImpl = options.fetch ?? fetch;

  const request = async (
    tenantId: string,
    action: "revoke" | "migrate",
    init: RequestInit,
  ): Promise<Response> => {
    let response: Response;
    try {
      response = await fetchImpl(
        `${baseUrl}/admin/tenants/${encodeURIComponent(tenantId)}/${
          action === "revoke" ? "revoke" : "migrate-hosted"
        }`,
        {
          ...init,
          headers: {
            authorization: `Bearer ${adminToken}`,
            "content-type": "application/json",
            ...init.headers,
          },
          signal: init.signal ?? AbortSignal.timeout(30_000),
        },
      );
    } catch {
      throw new LegacySubrouterRetirementError(action, null);
    }
    return response;
  };

  return {
    revokeTenant: async (tenantId, options) => {
      const response = await request(tenantId, "revoke", {
        method: "POST",
        signal: options?.signal,
      });
      if (response.status === 404) return { revoked: false };
      if (!response.ok) {
        throw new LegacySubrouterRetirementError("revoke", response.status);
      }
      return { revoked: true };
    },
    migrateTenant: async (tenantId, input) => {
      const response = await request(tenantId, "migrate", {
        method: "POST",
        body: JSON.stringify(input),
      });
      if (!response.ok) {
        throw new LegacySubrouterRetirementError("migrate", response.status);
      }
      const body = await safeJson(response, "migrate");
      if (
        !isRecord(body) ||
        body.ok !== true ||
        !Number.isSafeInteger(body.migrated) ||
        (body.migrated as number) < 0 ||
        body.sourceFinalized !== input.finalizeSource
      ) {
        throw new LegacySubrouterRetirementError("migrate", response.status);
      }
      return {
        migrated: body.migrated as number,
        sourceFinalized: body.sourceFinalized as boolean,
      };
    },
  };
}

async function safeJson(
  response: Response,
  operation: "revoke" | "migrate",
): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new LegacySubrouterRetirementError(operation, response.status);
  }
}

function assertSafeBaseUrl(raw: string): void {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error("legacy Subrouter retirement URL is invalid");
  }
  const loopback = parsed.hostname === "localhost" ||
    parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]";
  if (
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash ||
    (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback))
  ) {
    throw new Error("legacy Subrouter retirement URL is invalid");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
