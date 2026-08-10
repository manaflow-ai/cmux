import { readBoundedJsonRecord } from "../../../../services/subrouter/boundedJson";
import { resolveSubrouterRequestContext } from "../../../../services/subrouter/requestContext";
import { subrouterErrorResponse } from "../../../../services/subrouter/routeHelpers";
import type { SubrouterCredentialLeaseInput } from "../../../../services/subrouter/types";
import { jsonResponse } from "../../../../services/vms/routeHelpers";


const MAX_REQUEST_BYTES = 16 * 1024;

export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveSubrouterRequestContext(request);
  if (!resolved.ok) return resolved.response;
  const context = resolved.value;

  const body = await readLeaseInput(request);
  if (!body.ok) return jsonResponse({ error: "invalid_request" }, body.status);

  try {
    const tenant = await context.client.exchangeTeam(
      context.accessToken,
      context.team,
    );
    const lease = await context.client.createCredentialLease(
      tenant.tenantKey,
      body.value,
    );
    return new Response(JSON.stringify({
      teamId: context.team.teamId,
      lease,
    }), {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-type": "application/json",
      },
    });
  } catch (error) {
    return subrouterErrorResponse(error);
  }
}

async function readLeaseInput(
  request: Request,
): Promise<
  | { readonly ok: true; readonly value: SubrouterCredentialLeaseInput }
  | { readonly ok: false; readonly status: number }
> {
  const parsed = await readBoundedJsonRecord(request, MAX_REQUEST_BYTES);
  if (!parsed.ok) return parsed;
  const value = parsed.value;
  const provider = value.provider;
  const sessionId = normalizedString(value.sessionId, 512);
  if ((provider !== "codex" && provider !== "claude") || !sessionId) {
    return { ok: false, status: 400 };
  }
  const agentType = normalizedString(value.agentType, 64);
  const userEmail = normalizedString(value.userEmail, 320);
  const preferAccountId = normalizedString(value.preferAccountId, 256);
  const model = normalizedString(value.model, 256);
  const requiredAuthMode = value.requiredAuthMode;
  if (
    requiredAuthMode !== undefined &&
    requiredAuthMode !== "oauth" &&
    requiredAuthMode !== "apikey"
  ) {
    return { ok: false, status: 400 };
  }
  return {
    ok: true,
    value: {
      provider,
      sessionId,
      ...(agentType ? { agentType } : {}),
      ...(userEmail ? { userEmail } : {}),
      ...(preferAccountId ? { preferAccountId } : {}),
      ...(model ? { model } : {}),
      ...(requiredAuthMode ? { requiredAuthMode } : {}),
    },
  };
}

function normalizedString(value: unknown, maxLength: number): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized && normalized.length <= maxLength ? normalized : null;
}
