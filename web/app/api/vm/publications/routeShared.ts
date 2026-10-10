import { publicationApiCopy } from "../../../../services/vm-publications/copy";
import type * as Effect from "effect/Effect";

import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import { unauthorized, verifyRequest, type AuthedUser } from "../../../../services/vms/auth";
import {
  enforceBrowserMutationProtection,
  jsonResponse,
  resolveVmRouteAccountScope,
} from "../../../../services/vms/routeHelpers";
import { normalizePublicationAuthOrigin } from "../../../../services/vm-publications/security";
import {
  PublicationAccountDeletionBlockedError,
  PublicationConflictError,
  PublicationDatabaseError,
  PublicationNotFoundError,
} from "../../../../services/vm-publications/repository";
import { VmPublicationProviderError } from "../../../../services/vm-publications/provider";
import { isFreestyleTlsRuleLimit } from "../../../../services/vms/drivers/freestyleNetworkPolicy";
import { reportError } from "../../../../services/observability/report";
import {
  noteHandledRouteError,
  VM_ERROR_CODE_HEADER,
  withApiRouteSpan,
} from "../../../../services/telemetry";
import {
  DEFAULT_GENERATED_PUBLICATION_DOMAIN,
  PublicationConfigurationError,
  PublicationInputError,
  PublicationInvariantError,
  PublicationProvisioningBusyError,
  runVmPublicationWorkflow,
  type PublicationForwardAuthConfig,
  type PublicationPrincipal,
} from "../../../../services/vm-publications/workflows";
import type {
  CloudVmPublicationRepository,
} from "../../../../services/vm-publications/repository";
import type { VmPublicationProvider } from "../../../../services/vm-publications/provider";

export type PublicationProgram<A> = Effect.Effect<
  A,
  unknown,
  CloudVmPublicationRepository | VmPublicationProvider
>;

export type PublicationWorkflowRunner = <A>(program: PublicationProgram<A>) => Promise<A>;

export const livePublicationWorkflowRunner: PublicationWorkflowRunner =
  runVmPublicationWorkflow;

export type AuthedPublicationRouteContext = {
  readonly user: AuthedUser;
  readonly principal: PublicationPrincipal;
  readonly run: PublicationWorkflowRunner;
};

/**
 * Publication management requires fresh membership in the VM's owning team.
 * Do not reuse the native VM authentication cache or a stale team selection.
 */
export async function withAuthedPublicationApiRoute(
  request: Request,
  handler: (context: AuthedPublicationRouteContext) => Promise<Response>,
  run: PublicationWorkflowRunner = livePublicationWorkflowRunner,
  verify: typeof verifyRequest = verifyRequest,
): Promise<Response> {
  // One span per request with the error code and, for a 5xx, the caught
  // error's cause chain, so a provider failure is diagnosable from Axiom.
  return withApiRouteSpan(
    request,
    publicationRouteTemplate(request),
    { "cmux.subsystem": "vm-cloud", "cmux.vm.operation": "publication" },
    async (span) => {
      const response = await authedPublicationRoute(request, handler, run, verify);
      const code = response.headers.get(VM_ERROR_CODE_HEADER);
      if (code) span.setAttribute("cmux.vm.error_code", code);
      return response;
    },
  );
}

/**
 * The route template for a publication or domain path: ids and names become
 * `[id]` and `[name]`, so span names stay low-cardinality and carry no ids.
 */
export function publicationRouteTemplate(request: Request): string {
  const path = new URL(request.url).pathname.replace(/\/+$/u, "");
  return path
    .replace(/^(\/api\/vm\/publications)\/[^/]+/u, "$1/[id]")
    .replace(/^(\/api\/vm\/domains)\/[^/]+/u, "$1/[name]");
}

async function authedPublicationRoute(
  request: Request,
  handler: (context: AuthedPublicationRouteContext) => Promise<Response>,
  run: PublicationWorkflowRunner,
  verify: typeof verifyRequest,
): Promise<Response> {
  let user: AuthedUser | null;
  try {
    user = await verify(request, {
      listAllTeams: true,
      forceCompleteTeamList: true,
      requireFreshTeamMembership: true,
      requestedTeamId: await requestedPublicationTeamId(request),
    });
  } catch (error) {
    return authProviderErrorResponse(error, "vm.publications.auth");
  }
  if (!user) return unauthorized();
  const mutationForbidden = enforceBrowserMutationProtection(request);
  if (mutationForbidden) return mutationForbidden;
  const scope = resolveVmRouteAccountScope(user, request);
  if (!scope.ok) return scope.response;
  try {
    return await handler({
      user,
      principal: {
        userId: user.id,
        teamIds: user.teamIds,
        billingTeamId: scope.entitlements.billingTeamId,
        organizationName: user.teams.find((team) => team.id === scope.entitlements.billingTeamId)?.displayName ?? user.displayName ?? undefined,
      },
      run,
    });
  } catch (error) {
    console.error("Cloud VM publication request failed", error);
    noteHandledRouteError(error);
    return publicationErrorResponse(error, request.headers.get("accept-language"));
  }
}

/**
 * Read the team a publication request asks for before authentication so the
 * membership check can resolve it. Only mutation bodies carry one; the body is
 * cloned because the handler parses it again with full validation.
 */
export async function requestedPublicationTeamId(request: Request): Promise<string | null> {
  const method = request.method.toUpperCase();
  if (method !== "POST" && method !== "PATCH" && method !== "PUT") return null;
  try {
    const body: unknown = await request.clone().json();
    if (!body || typeof body !== "object" || Array.isArray(body)) return null;
    const teamId = (body as Record<string, unknown>).teamId;
    return typeof teamId === "string" && teamId.trim() ? teamId.trim() : null;
  } catch {
    return null;
  }
}

/**
 * Only the configured origin may become Freestyle's account-wide forward-auth
 * target. Deriving it from the request would let any caller's Host header
 * repoint every protected publication at their server and hand it the service
 * token, so an unset or malformed origin yields an empty URL that
 * `ensureSharedForwardAuth` rejects before provider I/O.
 */
export function publicationForwardAuthConfig(
  environment: Readonly<Record<string, string | undefined>> = process.env,
): PublicationForwardAuthConfig | undefined {
  const serviceToken = environment.CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET?.trim();
  if (!serviceToken) return undefined;
  const origin = normalizePublicationAuthOrigin(environment.CMUX_VM_PUBLICATION_AUTH_ORIGIN);
  return {
    url: origin ? new URL("/api/freestyle/forward-auth", origin).href : "",
    serviceToken,
  };
}

/** The zone generated hostnames are minted under; the operator owns its DNS and wildcard certificate. */
export function publicationGeneratedDomain(
  environment: Readonly<Record<string, string | undefined>> = process.env,
): string {
  return environment.CMUX_VM_PUBLICATION_GENERATED_DOMAIN?.trim() ||
    DEFAULT_GENERATED_PUBLICATION_DOMAIN;
}

const PUBLICATION_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

/**
 * Path segments name a publication by id or hostname. A bare generated label
 * such as `prickly-lavender-minnow` is completed with the generated zone so
 * the CLI can address generated names the way people say them.
 */
export function publicationReference(
  raw: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
): string {
  const value = raw.trim();
  if (!value || value.includes(".") || PUBLICATION_ID_PATTERN.test(value)) return value;
  return `${value}.${publicationGeneratedDomain(environment)}`;
}

export function publicationErrorResponse(error: unknown, language?: string | null): Response {
  if (error instanceof PublicationInputError) {
    const copy = inputErrorCopy(error, language);
    return publicationErrorJson({
      error: "vm_publication_invalid_request",
      message: copy.message,
      action: copy.action,
      reason: error.reason,
      details: { field: error.field },
    }, 400);
  }
  if (error instanceof PublicationNotFoundError) {
    return publicationErrorJson({
      error: "vm_publication_not_found",
      message: error.resource === "vm"
        ? "That Cloud VM was not found in your account or is not publishable."
        : "That Cloud VM publication was not found in your account.",
      action: error.resource === "vm"
        ? "Run `cmux cloud list`, then publish a running machine by its id."
        : "Run `cmux cloud domains list` and retry with a listed publication id.",
      reason: error.resource,
    }, 404);
  }
  if (error instanceof PublicationConflictError) {
    const copy = conflictCopy(error.reason, language);
    return publicationErrorJson({
      error: "vm_publication_conflict",
      message: copy.message,
      action: copy.action,
      reason: error.reason,
    }, copy.status);
  }
  if (error instanceof PublicationAccountDeletionBlockedError) {
    return publicationErrorJson({
      error: "vm_publication_account_deletion_in_progress",
      message: "Cloud VM domains cannot be changed while account deletion is in progress.",
      action: "Wait for account deletion to finish before changing publications.",
    }, 409);
  }
  if (error instanceof PublicationProvisioningBusyError) {
    const retryAfterSeconds = Math.max(
      1,
      Math.ceil((error.retryAt.getTime() - Date.now()) / 1_000),
    );
    return new Response(JSON.stringify({
      error: "vm_publication_provisioning_busy",
      message: "The Cloud VM domain is already being configured.",
      action: "Retry this command in a few seconds.",
      retryAfterSeconds,
    }), {
      status: 503,
      headers: {
        "content-type": "application/json",
        "retry-after": String(retryAfterSeconds),
        [VM_ERROR_CODE_HEADER]: "vm_publication_provisioning_busy",
      },
    });
  }
  if (error instanceof PublicationConfigurationError) {
    // Operator configuration names stay in server logs; clients get product guidance.
    const copy = configurationCopy(error.reason);
    return publicationErrorJson({
      error: "vm_publication_not_configured",
      message: copy.message,
      action: copy.action,
      reason: error.reason,
    }, 503);
  }
  if (error instanceof VmPublicationProviderError && hasTlsRuleLimitCause(error.cause)) {
    // The cap is shared by every machine on the account: the user cannot free
    // it and an immediate retry cannot succeed. The vm-alerts cron pages on
    // the same condition from the provider's rule count.
    reportTlsRuleLimit(error.operation);
    const copy = publicationApiCopy("rule_capacity", language);
    return publicationErrorJson({
      error: "vm_publication_rule_capacity",
      message: copy.message,
      action: copy.action,
      retryable: false,
    }, 503);
  }
  if (error instanceof VmPublicationProviderError) {
    return publicationErrorJson({
      error: "vm_publication_provider_unavailable",
      message: "The Cloud VM domain service could not complete this change.",
      action: "Run `cmux cloud domains list`; verify any provisioning entry, or retry if none exists. Contact support if it keeps failing.",
      retryable: true,
    }, 502);
  }
  if (error instanceof PublicationInvariantError || error instanceof PublicationDatabaseError) {
    return publicationErrorJson({
      error: "vm_publication_internal_error",
      message: "CMUX could not finish the Cloud VM domain change safely.",
      action: "Retry once. If it keeps failing, contact support with the publication id.",
    }, 500);
  }
  return publicationErrorJson({
    error: "vm_publication_internal_error",
    message: "Cloud VM publication failed unexpectedly.",
    action: "Retry once. If it keeps failing, contact support.",
  }, 500);
}

const TLS_RULE_LIMIT_REPORT_INTERVAL_MS = 10 * 60 * 1_000;
let lastTlsRuleLimitReportAt = Number.NEGATIVE_INFINITY;

/**
 * One operator error per instance per ten minutes: every refused publish at
 * the cap hits this path, and the vm-alerts cron already pages on the count.
 */
/** Test seam: forget the last report so each test starts with an open gate. */
export function resetTlsRuleLimitReportForTesting(): void {
  lastTlsRuleLimitReportAt = Number.NEGATIVE_INFINITY;
}

export function reportTlsRuleLimit(operation: string, now: number = Date.now()): boolean {
  if (now - lastTlsRuleLimitReportAt < TLS_RULE_LIMIT_REPORT_INTERVAL_MS) return false;
  lastTlsRuleLimitReportAt = now;
  reportError(
    new Error("Cloud VM provider TLS rule limit reached"),
    { subsystem: "cloud_vm_alerts", code: "provider_tls_rule_limit", operation, operatorFault: true },
    { fingerprint: ["cmux-vm-provider-tls-rule-limit", "freestyle"] },
  );
  return true;
}

/** A publication error body, tagged with its code so the route span records it. */
function publicationErrorJson(body: { readonly error: string } & Record<string, unknown>, status: number): Response {
  return jsonResponse(body, status, { [VM_ERROR_CODE_HEADER]: body.error });
}

/** Whether a provider failure, or anything in its cause chain, is Freestyle's TLS rule cap. */
function hasTlsRuleLimitCause(cause: unknown): boolean {
  let current = cause;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (isFreestyleTlsRuleLimit(current)) return true;
    current = typeof current === "object" ? (current as { cause?: unknown }).cause : undefined;
  }
  return false;
}

function inputErrorCopy(error: PublicationInputError, language?: string | null): {
  readonly message: string;
  readonly action: string;
} {
  switch (error.reason) {
    case "invalid_email":
      return publicationApiCopy("invalid_email", language);
    case "invalid_expiry":
      return publicationApiCopy("invalid_expiry", language);
    case "public_confirmation_required":
      return publicationApiCopy("public_confirmation_required", language);
    case "invalid_hostname":
      return {
        message: "hostname must be one exact DNS hostname.",
        action: "Pass a hostname such as preview.example.com, without a scheme, port, path, or wildcard.",
      };
    case "generated_hostname_reserved":
      return {
        message: "That hostname is inside a zone CMUX generates names from and cannot be selected with --domain.",
        action: "Omit --domain for a generated name, or pass a hostname on a domain you own.",
      };
    case "verification_not_required":
      return {
        message: "That name is a generated CMUX domain, which never needs verification.",
        action: "Verify a domain you own instead, or run `cmux cloud domains list` to see the publication's state.",
      };
    case "invalid_port":
      return {
        message: "port must be an integer between 1 and 65535.",
        action: "Pass the HTTP port listening inside the Cloud VM.",
      };
    case "reserved_port":
      return publicationApiCopy("reserved_port", language);
    case "team_required":
      return {
        message: "Team access requires a team id.",
        action: "Pass --team with one of your CMUX team ids.",
      };
    case "team_not_allowed":
      return {
        message: "You are not a member of the requested CMUX team.",
        action: "Choose one of your current teams or use personal access.",
      };
    case "invalid_access_mode":
      return {
        message: "accessMode must be personal, team, or public, and only team access accepts teamId.",
        action: "Choose personal, team, or public; include teamId only with team.",
      };
  }
}

function configurationCopy(reason: PublicationConfigurationError["reason"]): {
  readonly message: string;
  readonly action: string;
} {
  switch (reason) {
    case "invalid_auth_origin":
      return {
        message: "This CMUX deployment has no valid sign-in origin for protected Cloud VM domains.",
        action: "Ask the deployment operator to configure protected domains.",
      };
    case "invalid_generated_domain":
      return {
        message: "This CMUX deployment has no valid zone for generated Cloud VM domains.",
        action: "Pass --domain with a hostname you own, or ask the deployment operator to configure the generated zone.",
      };
    case "forward_auth_not_configured":
      return {
        message: "Protected Cloud VM domains are not configured on this CMUX deployment.",
        action: "Ask the deployment operator to enable protected domains.",
      };
  }
}

function conflictCopy(reason: PublicationConflictError["reason"], language?: string | null): {
  readonly message: string;
  readonly action: string;
  readonly status: number;
} {
  switch (reason) {
    case "organization_slug_reserved":
    case "organization_slug_taken":
    case "invalid_organization_slug":
      return { ...publicationApiCopy("organization_slug", language), status: 409 };
    case "hostname_taken":
      return {
        message: "That hostname is already reserved by a CMUX account.",
        action: "Choose another hostname, or remove the existing publication first.",
        status: 409,
      };
    case "domain_in_use":
      return {
        message: "That hostname already has a live CMUX publication.",
        action: "Update or remove the existing publication instead of creating a second one.",
        status: 409,
      };
    case "publication_revision_changed":
    case "forward_auth_bootstrap_lost":
    case "publication_operation_lost":
      return {
        message: "The publication changed while this request was running.",
        action: "List Cloud VM domains and retry against the latest state.",
        status: 409,
      };
    case "vm_publication_frozen":
      return {
        message: "That Cloud VM is already being removed.",
        action: "Choose another running Cloud VM for this domain.",
        status: 409,
      };
    case "publication_failed":
      return { ...publicationApiCopy("publication_failed", language), status: 409 };
    case "publication_not_active":
      return {
        message: "That publication is not ready for this change.",
        action: "Run `cmux cloud domains verify <id>` until it is active, then retry.",
        status: 409,
      };
    case "invalid_access_policy":
      return {
        message: "The requested access policy is inconsistent.",
        action: "Use personal, team, or public; include a team id only for team access.",
        status: 409,
      };
    default:
      return {
        message: "The Cloud VM publication conflicts with existing state.",
        action: "List Cloud VM domains and retry against the latest state.",
        status: 409,
      };
  }
}
