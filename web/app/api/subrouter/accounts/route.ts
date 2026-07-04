import { cloudDb } from "../../../../db/client";
import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requestedVmTeamIdFromRequest,
  requiresBrowserMutationProtection,
} from "../../../../services/vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
} from "../../../../services/vms/auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  type ClaudeAccountInput,
  type CodexAccountInput,
  type SubrouterAccountInput,
} from "../../../../services/subrouter/client";
import {
  resolveTeam,
  serviceUnavailableResponse,
  subrouterErrorResponse,
} from "../../../../services/subrouter/routeHelpers";
import { getOrCreateTenantForTeam } from "../../../../services/subrouter/tenants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_REQUEST_BYTES = 64 * 1024;
const MAX_LABEL_LENGTH = 120;

export async function GET(request: Request): Promise<Response> {
  const context = await resolveRequestContext(request);
  if (!context.ok) return context.response;

  try {
    const tenant = await getOrCreateTenantForTeam(
      cloudDb(),
      context.team.teamId,
      context.team.teamName,
      {
        client: context.client,
        tenantKeySecret: context.config.tenantKeySecret,
      },
    );
    const accounts = await context.client.listAccounts(tenant.tenantKey);
    return jsonResponse({ teamId: context.team.teamId, accounts });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}

export async function POST(request: Request): Promise<Response> {
  const context = await resolveRequestContext(request);
  if (!context.ok) return context.response;

  const body = await readBoundedJson(request);
  if (!body.ok) return jsonResponse({ error: "invalid_request" }, body.status);

  const input = validateAccountInput(body.value);
  if (!input.ok) return jsonResponse({ error: "invalid_request" }, 400);

  const validate = requestUrl(request)?.searchParams.get("validate") === "1";

  try {
    const tenant = await getOrCreateTenantForTeam(
      cloudDb(),
      context.team.teamId,
      context.team.teamName,
      {
        client: context.client,
        tenantKeySecret: context.config.tenantKeySecret,
      },
    );
    const account = await context.client.createAccount(tenant.tenantKey, input.value, { validate });
    return jsonResponse({ teamId: context.team.teamId, account });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}

async function resolveRequestContext(request: Request): Promise<
  | {
    ok: true;
    team: { teamId: string; teamName: string };
    config: NonNullable<ReturnType<typeof subrouterRuntimeConfig>>;
    client: ReturnType<typeof createSubrouterClient>;
  }
  | { ok: false; response: Response }
> {
  const requestedTeamId = requestedVmTeamIdFromRequest(request);
  const user = await verifyRequest(request, {
    requestedTeamId,
    allowCookie: true,
  });
  if (!user) return { ok: false, response: unauthorized() };
  const bearer = parseBearer(request);
  if (requiresBrowserMutationProtection(request.method, bearer) && !browserMutationOriginAllowed(request)) {
    return {
      ok: false,
      response: jsonResponse({ error: "forbidden" }, 403),
    };
  }

  const team = resolveTeam(request, user);
  if (!team.ok) return team;

  const config = subrouterRuntimeConfig();
  if (!config) {
    return {
      ok: false,
      response: serviceUnavailableResponse(),
    };
  }

  return {
    ok: true,
    team,
    config,
    client: createSubrouterClient({
      baseUrl: config.baseUrl,
      adminToken: config.adminToken,
    }),
  };
}

async function readBoundedJson(
  request: Request,
): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; status: number }> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader && Number(lengthHeader) > MAX_REQUEST_BYTES) {
    return { ok: false, status: 413 };
  }
  const bounded = await readBoundedBody(request, MAX_REQUEST_BYTES);
  if (!bounded.ok) return bounded;
  const raw = bounded.value;

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, status: 400 };
  }
  if (!isRecord(parsed)) return { ok: false, status: 400 };
  return { ok: true, value: parsed };
}

function validateAccountInput(
  body: Record<string, unknown>,
): { ok: true; value: SubrouterAccountInput } | { ok: false } {
  const provider = body.provider;
  if (typeof provider !== "string") return { ok: false };
  const label = optionalLabel(body.label);
  if (label === false) return { ok: false };

  switch (provider) {
    case "claude": {
      const claudeAiOauth = body.claudeAiOauth;
      if (!isRecord(claudeAiOauth)) return { ok: false };
      if (!requiredString(claudeAiOauth.accessToken) || !requiredString(claudeAiOauth.refreshToken)) {
        return { ok: false };
      }
      if (
        typeof claudeAiOauth.expiresAt !== "string" &&
        typeof claudeAiOauth.expiresAt !== "number"
      ) {
        return { ok: false };
      }
      return {
        ok: true,
        value: { provider, ...(label ? { label } : {}), claudeAiOauth: claudeAiOauth as ClaudeAccountInput["claudeAiOauth"] },
      };
    }
    case "anthropic-apikey": {
      const apiKey = trimmedString(body.apiKey);
      if (!apiKey.startsWith("sk-ant-")) return { ok: false };
      return {
        ok: true,
        value: { provider, ...(label ? { label } : {}), apiKey },
      };
    }
    case "codex": {
      const tokens = body.tokens;
      if (!isRecord(tokens)) return { ok: false };
      if (
        !requiredString(tokens.accessToken) ||
        !requiredString(tokens.refreshToken) ||
        !requiredString(tokens.idToken) ||
        !requiredString(tokens.accountID)
      ) {
        return { ok: false };
      }
      return {
        ok: true,
        value: { provider, ...(label ? { label } : {}), tokens: tokens as CodexAccountInput["tokens"] },
      };
    }
    case "openai-apikey": {
      const apiKey = trimmedString(body.apiKey);
      if (!apiKey.startsWith("sk-")) return { ok: false };
      return {
        ok: true,
        value: { provider, ...(label ? { label } : {}), apiKey },
      };
    }
    default:
      return { ok: false };
  }
}

function optionalLabel(value: unknown): string | false | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > MAX_LABEL_LENGTH) return false;
  return trimmed;
}

function requiredString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function trimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

async function readBoundedBody(
  request: Request,
  maxBytes: number,
): Promise<{ ok: true; value: string } | { ok: false; status: number }> {
  const body = request.body;
  if (!body) return { ok: true, value: "" };

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel().catch(() => {});
        return { ok: false, status: 413 };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, status: 400 };
  }

  const merged = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, value: new TextDecoder().decode(merged) };
}

function requestUrl(request: Request): URL | null {
  try {
    return new URL(request.url);
  } catch {
    return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
