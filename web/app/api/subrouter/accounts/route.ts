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
  type AuthedUser,
} from "../../../../services/vms/auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  SubrouterClientError,
  SubrouterNotConfiguredError,
  type ClaudeAccountInput,
  type CodexAccountInput,
  type SubrouterAccountInput,
} from "../../../../services/subrouter/client";
import { SubrouterTenantKeySecretError } from "../../../../services/subrouter/crypto";
import { getOrCreateTenantForTeam } from "../../../../services/subrouter/tenants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_REQUEST_BYTES = 64 * 1024;
const MAX_LABEL_LENGTH = 120;

type TeamResolution =
  | { ok: true; teamId: string; teamName: string }
  | { ok: false; response: Response };

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
      response: jsonResponse({ error: "subrouter not configured" }, 503),
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

function resolveTeam(request: Request, user: AuthedUser): TeamResolution {
  const requested = requestedVmTeamIdFromRequest(request);
  if (requested) {
    const isMember = user.teamIds.includes(requested) || requested === user.id;
    if (!isMember) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_not_found" }, 403),
      };
    }
    return {
      ok: true,
      teamId: requested,
      teamName: teamDisplayName(user, requested),
    };
  }

  const teamId = user.selectedTeamId ?? user.billingTeamId;
  return {
    ok: true,
    teamId,
    teamName: teamDisplayName(user, teamId),
  };
}

function teamDisplayName(user: AuthedUser, teamId: string): string {
  if (teamId === user.id) {
    return user.displayName ?? user.primaryEmail ?? user.id;
  }
  const team = user.teams.find((candidate) => candidate.id === teamId);
  return team?.displayName ?? teamId;
}

async function readBoundedJson(
  request: Request,
): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; status: number }> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader && Number(lengthHeader) > MAX_REQUEST_BYTES) {
    return { ok: false, status: 413 };
  }
  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return { ok: false, status: 400 };
  }
  if (raw.length > MAX_REQUEST_BYTES) return { ok: false, status: 413 };

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

function subrouterErrorResponse(err: unknown): Response {
  if (err instanceof SubrouterNotConfiguredError || err instanceof SubrouterTenantKeySecretError) {
    return jsonResponse({ error: "subrouter not configured" }, 503);
  }
  if (err instanceof SubrouterClientError) {
    const status = err.status !== null && err.status >= 400 && err.status < 500
      ? err.status
      : 502;
    return jsonResponse({ error: "subrouter_request_failed" }, status);
  }
  return jsonResponse({ error: "subrouter_request_failed" }, 500);
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
