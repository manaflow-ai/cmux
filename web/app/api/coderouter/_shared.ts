import { z } from "zod";
import { unauthorized, verifyRequest, type AuthedUser } from "../../../services/vms/auth";
import { jsonResponse, requestedVmTeamIdFromRequest } from "../../../services/vms/routeHelpers";
import {
  CoderouterBillingError,
  CoderouterConfigurationError,
  CoderouterConnectError,
  CoderouterDatabaseError,
  CoderouterNotFoundError,
  CoderouterWorkerSyncError,
} from "../../../services/coderouter/errors";
import type { BillingCustomer } from "../../../services/coderouter/billing";

export const PUBLIC_JSON_LIMIT_BYTES = 64 * 1024;
export const USAGE_INGEST_JSON_LIMIT_BYTES = 2 * 1024 * 1024;

export type AuthedCoderouterContext = {
  readonly user: AuthedUser;
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
};

export const credentialClassSchema = z.enum(["oauth", "byok", "managed"]);
export const familySchema = z.enum(["anthropic", "openai"]);
export const keyPolicySchema = z.object({
  allowedClasses: z.array(credentialClassSchema).optional(),
}).strict().optional();

export async function authenticateCoderouter(request: Request): Promise<
  | { readonly ok: true; readonly context: AuthedCoderouterContext }
  | { readonly ok: false; readonly response: Response }
> {
  const user = await verifyRequest(request, {
    requestedTeamId: requestedVmTeamIdFromRequest(request),
    allowCookie: false,
  });
  if (!user) return { ok: false, response: unauthorized() };

  const requested = requestedVmTeamIdFromRequest(request);
  if (requested) {
    const isMember = user.teamIds.includes(requested) || requested === user.id;
    if (!isMember) return { ok: false, response: jsonResponse({ error: "team_not_found" }, 403) };
    const requestedIsUser = requested === user.id && !user.teamIds.includes(requested);
    return {
      ok: true,
      context: {
        user,
        teamId: requested,
        billingCustomer: { type: requestedIsUser ? "user" : "team", id: requested },
      },
    };
  }

  const teamId = user.selectedTeamId ?? user.billingTeamId;
  return {
    ok: true,
    context: {
      user,
      teamId,
      billingCustomer: { type: user.billingCustomerType, id: user.billingTeamId },
    },
  };
}

export async function parseJsonBody<T>(
  request: Request,
  schema: z.ZodType<T>,
  maxBytes = PUBLIC_JSON_LIMIT_BYTES,
): Promise<{ readonly ok: true; readonly value: T } | { readonly ok: false; readonly response: Response }> {
  const length = request.headers.get("content-length");
  if (length && Number(length) > maxBytes) {
    return { ok: false, response: jsonResponse({ error: "payload_too_large", message: "Request body is too large." }, 413) };
  }
  const raw = await request.text().catch(() => null);
  if (raw === null || raw.length > maxBytes) {
    return { ok: false, response: jsonResponse({ error: "invalid_request", message: "Request body could not be read." }, 400) };
  }
  let parsed: unknown;
  try {
    parsed = raw ? JSON.parse(raw) : {};
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json", message: "Request body must be JSON." }, 400) };
  }
  const result = schema.safeParse(parsed);
  if (!result.success) {
    return {
      ok: false,
      response: jsonResponse({
        error: "invalid_request",
        message: "Request body failed validation.",
        issues: z.treeifyError(result.error),
      }, 400),
    };
  }
  return { ok: true, value: result.data };
}

export function coderouterErrorResponse(err: unknown): Response {
  if (err instanceof CoderouterConfigurationError) {
    return jsonResponse({ error: "coderouter_not_configured", message: err.message }, 503);
  }
  if (err instanceof CoderouterWorkerSyncError) {
    return jsonResponse({ error: "worker_sync_failed", message: "Could not sync coderouter worker state." }, 502);
  }
  if (err instanceof CoderouterDatabaseError) {
    return jsonResponse({ error: "coderouter_state_unavailable", message: "Coderouter state is temporarily unavailable." }, 503);
  }
  if (err instanceof CoderouterBillingError) {
    return jsonResponse({ error: "coderouter_billing_unavailable", message: "Coderouter billing could not be updated." }, 503);
  }
  if (err instanceof CoderouterConnectError) {
    const status = err.code === "provider_rejected" ? 502 : 400;
    return jsonResponse({ error: err.code, message: err.message }, status);
  }
  if (err instanceof CoderouterNotFoundError) {
    return jsonResponse({ error: "not_found", message: err.message }, 404);
  }
  return jsonResponse({ error: "coderouter_internal_error", message: "Coderouter request failed unexpectedly." }, 500);
}

export function cookieValue(request: Request, name: string): string | null {
  const cookie = request.headers.get("cookie");
  if (!cookie) return null;
  for (const part of cookie.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=") || null;
  }
  return null;
}
