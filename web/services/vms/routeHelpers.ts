import type { Span } from "@opentelemetry/api";
import { recordSpanError, withApiRouteSpan, type MaybeAttributes } from "../telemetry";
import { unauthorized, verifyRequest, type AuthedUser } from "./auth";
import {
  isVmBillingTeamResolutionError,
  resolveVmEntitlements,
  type VmEntitlements,
} from "./entitlements";
import {
  isVmBillingError,
  isVmDatabaseError,
  isVmProviderOperationError,
  vmWorkflowErrorCause,
} from "./errors";
import { recordSpanTiming } from "./timings";

/** Bearer + refresh token pair the mac app stashes in keychain. */
export type StackBearer = { accessToken: string; refreshToken: string };

export function parseBearer(request: Request): StackBearer | null {
  const auth = request.headers.get("authorization");
  const refresh = request.headers.get("x-stack-refresh-token");
  if (!auth?.toLowerCase().startsWith("bearer ") || !refresh) return null;
  const accessToken = auth.slice("bearer ".length).trim();
  const refreshToken = refresh.trim();
  if (!accessToken || !refreshToken) return null;
  return { accessToken, refreshToken };
}

export type AuthedVmRouteContext = {
  user: AuthedUser;
  span: Span;
  authDurationMs: number;
  routeStartedAtMs: number;
  setResponseFinalizer: (finalizer: ((response: Response) => void) | null) => void;
};

export async function withAuthedVmApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  failureLog: string,
  handler: (context: AuthedVmRouteContext) => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    { "cmux.subsystem": "vm-cloud", ...attributes },
    async (span) => {
      let responseFinalizer: ((response: Response) => void) | null = null;
      const setResponseFinalizer = (finalizer: ((response: Response) => void) | null) => {
        responseFinalizer = finalizer;
      };
      const finalize = (response: Response): Response => {
        if (!responseFinalizer) return response;
        try {
          responseFinalizer(response);
        } catch (err) {
          recordSpanError(span, err);
          console.error(`${failureLog}: response finalizer failed`, err);
        }
        return response;
      };

      try {
        const routeStartedAtMs = performance.now();
        const bearer = parseBearer(request);
        const authStart = performance.now();
        const user = await verifyRequest(request, { requestedTeamId: requestedVmTeamIdFromRequest(request) });
        const authDurationMs = performance.now() - authStart;
        recordSpanTiming(span, "auth", authDurationMs);
        if (!user) return unauthorized();
        if (requiresBrowserMutationProtection(request.method, bearer) && !browserMutationOriginAllowed(request)) {
          return jsonResponse({ error: "forbidden" }, 403);
        }
        return finalize(await handler({ user, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }));
      } catch (err) {
        recordSpanError(span, err);
        console.error(failureLog, err);
        const workflowError = vmWorkflowErrorResponse(err);
        if (workflowError) return finalize(workflowError);
        return finalize(vmErrorResponse({
          error: "vm_internal_error",
          status: 500,
          message: "Cloud VM request failed unexpectedly.",
          action: "Try again. If it keeps failing, copy this error and contact support so we can inspect the server logs.",
          details: { route },
        }));
      }
    },
  );
}

/**
 * `Response.json(...)` misbehaves under Next.js 16's turbopack dev build (the handler's
 * promise settles but turbopack reports "No response is returned from route handler").
 * Use `new Response(JSON.stringify(...), { ... })` explicitly instead.
 */
export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export type VmErrorResponseInput = {
  readonly error: string;
  readonly message: string;
  readonly action: string;
  readonly status: number;
  readonly reason?: string;
  readonly extra?: Record<string, unknown>;
  readonly details?: Record<string, unknown>;
  readonly phase?: VmLifecyclePhase;
  readonly retryable?: boolean;
  readonly retryAfterSeconds?: number;
  readonly displayTitle?: string;
  readonly displayMessage?: string;
  readonly severity?: "info" | "warning" | "error";
};

export type VmLifecyclePhase =
  | "auth"
  | "billing"
  | "create"
  | "restore"
  | "fork"
  | "snapshot"
  | "resume"
  | "attach"
  | "ssh"
  | "exec"
  | "destroy"
  | "status"
  | "list"
  | "unknown";

export function vmErrorResponse(input: VmErrorResponseInput): Response {
  const retryAfterSeconds = normalizedRetryAfterSeconds(input.retryAfterSeconds);
  const payload = {
    ...(input.extra ?? {}),
    ...(input.details ? { details: {
      ...input.details,
      ...(input.phase ? { phase: input.phase } : {}),
      ...(input.retryable !== undefined ? { retryable: input.retryable } : {}),
      ...(retryAfterSeconds !== undefined ? { retryAfterSeconds } : {}),
    } } : {}),
    ...(input.phase ? { phase: input.phase } : {}),
    ...(input.retryable !== undefined ? { retryable: input.retryable } : {}),
    ...(retryAfterSeconds !== undefined ? { retryAfterSeconds } : {}),
    ui: {
      title: input.displayTitle ?? defaultVmDisplayTitle(input),
      message: input.displayMessage ?? input.message,
      phase: input.phase ?? "unknown",
      severity: input.severity ?? (input.status >= 500 ? "warning" : "error"),
      retryable: input.retryable ?? false,
      ...(retryAfterSeconds !== undefined ? { retryAfterSeconds } : {}),
    },
    error: input.error,
    message: input.message,
    reason: input.reason ?? input.message,
    action: input.action,
  };
  const headers: Record<string, string> = {};
  if (retryAfterSeconds !== undefined) {
    headers["retry-after"] = String(retryAfterSeconds);
  }
  return new Response(JSON.stringify(payload), {
    status: input.status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export function notFoundVm(vmId: string): Response {
  return vmErrorResponse({
    error: "vm_not_found",
    status: 404,
    message: `Cloud VM ${vmId} was not found.`,
    action: "Run `cmux vm ls` to see available Cloud VMs. If the VM stopped while idle, start a new one with `cmux vm new`.",
    details: { vmId },
  });
}

export type VmRouteAccountScope =
  | {
    readonly ok: true;
    readonly requestedBillingTeamId: string | null;
    readonly entitlements: VmEntitlements;
  }
  | {
    readonly ok: false;
    readonly response: Response;
  };

export function resolveVmRouteAccountScope(
  user: AuthedUser,
  request: Request,
  options: { readonly requireTeam?: boolean } = {},
): VmRouteAccountScope {
  const requestedBillingTeamId = requestedVmTeamIdFromRequest(request);
  try {
    return {
      ok: true,
      requestedBillingTeamId,
      entitlements: resolveVmEntitlements(user, process.env, {
        requestedBillingTeamId,
        requireTeam: options.requireTeam ?? false,
      }),
    };
  } catch (err) {
    if (isVmBillingTeamResolutionError(err)) {
      return { ok: false, response: vmBillingTeamErrorResponse(err) };
    }
    throw err;
  }
}

export function vmBillingTeamErrorResponse(err: {
  readonly code: "vm_billing_team_required" | "vm_billing_team_not_found";
  readonly status: number;
  readonly message: string;
}): Response {
  return vmErrorResponse({
    error: err.code,
    status: err.status,
    message: err.code === "vm_billing_team_not_found"
      ? "That team is not available for this account."
      : "cmux needs to know which team should own this Cloud VM.",
    action: err.code === "vm_billing_team_not_found"
      ? "Switch to a team you belong to, or run `cmux auth login` again and retry with the correct team id."
      : "Select a team in cmux, or pass the team id with `X-Cmux-Team-Id`.",
    reason: err.message,
  });
}

export function vmWorkflowErrorResponse(err: unknown): Response | null {
  const workflowError = vmWorkflowErrorCause(err) ?? err;
  if (isVmProviderOperationError(workflowError)) {
    const providerCause = providerCauseSummary(workflowError.cause);
    const phase = vmPhaseForOperation(workflowError.operation);
    const retryAfterSeconds = retryAfterForOperation(workflowError.operation);
    const providerMessage = providerCause?.message
      ? sanitizedProviderMessage(providerCause.message)
      : null;
    const providerCode = providerCause?.code
      ? sanitizedProviderCode(providerCause.code)
      : inferredProviderCode(providerMessage);
    return vmErrorResponse({
      error: "vm_cloud_service_unavailable",
      status: 502,
      message: vmUnavailableMessage(phase),
      reason: providerMessage
        ? `Cloud VM service is temporarily unavailable: ${providerMessage}`
        : "Cloud VM service is temporarily unavailable.",
      action: cloudServiceAction(workflowError.operation, retryAfterSeconds),
      phase,
      retryable: true,
      retryAfterSeconds,
      displayTitle: vmUnavailableTitle(phase),
      displayMessage: vmUnavailableDisplayMessage(phase, retryAfterSeconds),
      details: {
        operation: workflowError.operation,
        retryable: true,
        ...(providerCode ? { providerCode } : {}),
        ...(providerMessage ? { providerMessage } : {}),
      },
    });
  }

  if (isVmDatabaseError(workflowError)) {
    return vmErrorResponse({
      error: "vm_cloud_state_unavailable",
      status: 503,
      message: "Cloud VM state is temporarily unavailable.",
      action: "Retry in a minute. If this keeps happening, contact support so we can check Cloud VM state for your account.",
      phase: vmPhaseForOperation(workflowError.operation),
      retryable: true,
      retryAfterSeconds: 60,
      displayTitle: "Cloud VM state is unavailable",
      displayMessage: "Retrying is safe. The VM state database did not answer this request.",
      details: { operation: workflowError.operation },
    });
  }

  if (isVmBillingError(workflowError)) {
    return vmErrorResponse({
      error: "vm_billing_unavailable",
      status: 503,
      message: "Cloud VM billing could not be checked right now.",
      action: "Retry in a minute. If the problem persists, ask an admin to check this team's Cloud VM billing setup.",
      phase: "billing",
      retryable: true,
      retryAfterSeconds: 60,
      displayTitle: "Cloud VM billing is unavailable",
      displayMessage: "Retrying is safe. Billing state could not be checked for this request.",
      details: { operation: workflowError.operation },
    });
  }

  return null;
}

function providerCauseSummary(cause: unknown): { code?: string; message?: string } | null {
  let current: unknown = cause;
  let fallback: { code?: string; message?: string } | null = null;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    const record = current as {
      body?: { code?: unknown; message?: unknown };
      cause?: unknown;
      message?: unknown;
    };
    const code = typeof record.body?.code === "string" ? record.body.code.trim() : "";
    const bodyMessage = typeof record.body?.message === "string" ? record.body.message.trim() : "";
    const message = typeof record.message === "string" ? record.message.trim() : "";
    const summaryMessage = bodyMessage || message;
    if (code) {
      return {
        code,
        ...(summaryMessage ? { message: summaryMessage } : {}),
      };
    }
    if (!fallback && summaryMessage) fallback = { message: summaryMessage };
    current = record.cause;
  }
  return fallback;
}

function cloudServiceAction(operation: string, retryAfterSeconds: number | undefined): string {
  const retryPrefix = retryAfterSeconds
    ? `cmux will retry in about ${retryAfterSeconds}s when this request is part of an attach loop. `
    : "";
  switch (operation) {
    case "create":
      return `${retryPrefix}Retry once. If it fails again, run \`cmux vm ls\` to check whether a VM was created, then try \`cmux vm new\` again or contact support.`;
    case "openAttach":
    case "openSSH":
      return `${retryPrefix}cmux is retrying attach while the Cloud VM service recovers. Run \`cmux vm ls\` to confirm the VM still exists.`;
    case "exec":
      return `${retryPrefix}Check that the VM is still running with \`cmux vm ls\`, then retry the command. For long commands, increase the exec timeout.`;
    case "destroy":
      return `${retryPrefix}Run \`cmux vm ls\` to see whether the VM is already gone. If it still appears, retry \`cmux vm rm <id>\`.`;
    default:
      return `${retryPrefix}Retry the command. If it keeps failing, copy this error and contact support.`;
  }
}

function defaultVmDisplayTitle(input: VmErrorResponseInput): string {
  if (input.status === 409) return "Cloud VM operation already running";
  if (input.status === 404) return "Cloud VM not found";
  if (input.status === 401 || input.status === 403) return "Cloud VM authentication required";
  if (input.status === 402) return "Cloud VM limit reached";
  if (input.status >= 500) return "Cloud VM temporarily unavailable";
  return "Cloud VM request failed";
}

function normalizedRetryAfterSeconds(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value) || value <= 0) return undefined;
  return Math.max(1, Math.min(3600, Math.round(value)));
}

function vmPhaseForOperation(operation: string): VmLifecyclePhase {
  if (operation.includes("openAttach")) return "attach";
  if (operation.includes("openSSH")) return "ssh";
  if (operation.includes("create")) return "create";
  if (operation.includes("restore")) return "restore";
  if (operation.includes("fork")) return "fork";
  if (operation.includes("snapshot")) return "snapshot";
  if (operation.includes("resume")) return "resume";
  if (operation.includes("exec")) return "exec";
  if (operation.includes("destroy")) return "destroy";
  if (operation.includes("getStatus")) return "status";
  if (operation.includes("list")) return "list";
  return "unknown";
}

function retryAfterForOperation(operation: string): number | undefined {
  const phase = vmPhaseForOperation(operation);
  switch (phase) {
    case "attach":
    case "ssh":
      return 2;
    case "create":
    case "restore":
    case "fork":
      return 5;
    case "exec":
    case "status":
      return 3;
    default:
      return undefined;
  }
}

function vmUnavailableTitle(phase: VmLifecyclePhase): string {
  switch (phase) {
    case "attach":
      return "Reconnecting Cloud VM";
    case "ssh":
      return "Refreshing Cloud VM credentials";
    case "create":
      return "Creating Cloud VM";
    case "restore":
      return "Restoring Cloud VM";
    case "fork":
      return "Forking Cloud VM";
    case "exec":
      return "Cloud VM command unavailable";
    default:
      return "Cloud VM temporarily unavailable";
  }
}

function vmUnavailableMessage(phase: VmLifecyclePhase): string {
  switch (phase) {
    case "attach":
      return "cmux could not attach to the Cloud VM yet.";
    case "ssh":
      return "cmux could not refresh Cloud VM SSH credentials yet.";
    case "create":
      return "cmux could not create the Cloud VM yet.";
    case "restore":
      return "cmux could not restore the Cloud VM yet.";
    case "fork":
      return "cmux could not fork the Cloud VM yet.";
    case "exec":
      return "cmux could not run the Cloud VM command yet.";
    default:
      return "The Cloud VM service could not complete this request yet.";
  }
}

function vmUnavailableDisplayMessage(phase: VmLifecyclePhase, retryAfterSeconds: number | undefined): string {
  const suffix = retryAfterSeconds ? ` Retrying in ${retryAfterSeconds}s.` : " Retrying is safe.";
  return `${vmUnavailableMessage(phase)}${suffix}`;
}

function sanitizedProviderMessage(message: string): string {
  const normalized = message.trim();
  if (!normalized) return "";
  if (/internal/i.test(normalized) && /error/i.test(normalized)) return "internal service error";
  if (/timeout|timed out|aborted/i.test(normalized)) return "request timed out";
  if (/rate[_\s-]*limit|too many requests/i.test(normalized)) return "rate limited";
  if (/not found|deleted/i.test(normalized)) return "VM not found";
  return normalized
    .replace(/freestyle/gi, "Cloud VM")
    .replace(/e2b/gi, "Cloud VM")
    .slice(0, 240);
}

function sanitizedProviderCode(code: string): string {
  const normalized = code.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  if (!normalized) return "";
  if (normalized.includes("internal")) return "provider_internal";
  if (normalized.includes("timeout") || normalized.includes("aborted")) return "provider_timeout";
  if (normalized.includes("rate")) return "provider_rate_limited";
  if (normalized.includes("not_found") || normalized.includes("deleted")) return "provider_not_found";
  return normalized.slice(0, 80);
}

function inferredProviderCode(message: string | null): string | null {
  if (!message) return null;
  if (message === "internal service error") return "provider_internal";
  if (message === "request timed out") return "provider_timeout";
  if (message === "rate limited") return "provider_rate_limited";
  if (message === "VM not found") return "provider_not_found";
  return null;
}

export function requestedVmTeamIdFromRequest(request: Request): string | null {
  const fromHeader = normalizedOptionalString(
    request.headers.get("x-cmux-team-id") ??
      request.headers.get("x-cmux-billing-team-id"),
  );
  if (fromHeader) return fromHeader;

  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return null;
  }

  return normalizedOptionalString(
    url.searchParams.get("teamId") ??
      url.searchParams.get("team_id") ??
      url.searchParams.get("billingTeamId") ??
      url.searchParams.get("billing_team_id"),
  );
}

function requiresBrowserMutationProtection(method: string, bearer: StackBearer | null): boolean {
  if (!["POST", "PUT", "PATCH", "DELETE"].includes(method.toUpperCase())) {
    return false;
  }
  return bearer === null;
}

function browserMutationOriginAllowed(request: Request): boolean {
  const origin = request.headers.get("origin")?.trim();
  const secFetchSite = request.headers.get("sec-fetch-site")?.trim().toLowerCase();

  if (secFetchSite === "cross-site") return false;
  if (!origin) return false;

  const requestOrigin = requestURLOrigin(request);
  if (requestOrigin && origin === requestOrigin) return true;
  return allowedBrowserOrigins().has(origin);
}

function requestURLOrigin(request: Request): string | null {
  try {
    return new URL(request.url).origin;
  } catch {
    return null;
  }
}

let cachedAllowedOriginsEnv: string | undefined;
let cachedAllowedOrigins: Set<string> | null = null;

// CMUX_VM_ALLOWED_ORIGINS is a comma-separated list of full origins that must match
// the Origin header exactly, for example `https://app.example.com,https://staging.example.com`.
// Do not include paths, schemeless hosts, or trailing slashes.
function allowedBrowserOrigins(): Set<string> {
  const raw = process.env.CMUX_VM_ALLOWED_ORIGINS;
  if (cachedAllowedOrigins && cachedAllowedOriginsEnv === raw) return cachedAllowedOrigins;
  cachedAllowedOriginsEnv = raw;
  const configured = raw?.split(",") ?? [];
  cachedAllowedOrigins = new Set(
    configured
      .map((origin) => origin.trim())
      .filter((origin) => origin.length > 0),
  );
  return cachedAllowedOrigins;
}

function normalizedOptionalString(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}
