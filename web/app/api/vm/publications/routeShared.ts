import type * as Effect from "effect/Effect";

import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import { unauthorized, verifyRequest, type AuthedUser } from "../../../../services/vms/auth";
import {
  enforceBrowserMutationProtection,
  jsonResponse,
} from "../../../../services/vms/routeHelpers";
import {
  PublicationAccountDeletionBlockedError,
  PublicationConflictError,
  PublicationDatabaseError,
  PublicationNotFoundError,
} from "../../../../services/vm-publications/repository";
import { VmPublicationProviderError } from "../../../../services/vm-publications/provider";
import {
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

/** Publication policy needs all current Stack teams, not just the selected billing team. */
export async function withAuthedPublicationApiRoute(
  request: Request,
  handler: (context: AuthedPublicationRouteContext) => Promise<Response>,
  run: PublicationWorkflowRunner = livePublicationWorkflowRunner,
): Promise<Response> {
  let user: AuthedUser | null;
  try {
    user = await verifyRequest(request, { listAllTeams: true });
  } catch (error) {
    return authProviderErrorResponse(error, "vm.publications.auth");
  }
  if (!user) return unauthorized();
  const mutationForbidden = enforceBrowserMutationProtection(request);
  if (mutationForbidden) return mutationForbidden;
  try {
    return await handler({
      user,
      principal: { userId: user.id, teamIds: user.teamIds },
      run,
    });
  } catch (error) {
    console.error("Cloud VM publication request failed", error);
    return publicationErrorResponse(error);
  }
}

export function publicationForwardAuthConfig(
  request: Request,
  environment: NodeJS.ProcessEnv = process.env,
): PublicationForwardAuthConfig | undefined {
  const serviceToken = environment.CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET?.trim();
  if (!serviceToken) return undefined;
  const configuredOrigin = environment.CMUX_VM_PUBLICATION_AUTH_ORIGIN?.trim();
  try {
    const origin = new URL(configuredOrigin || request.url).origin;
    return {
      url: new URL("/api/freestyle/forward-auth", origin).href,
      serviceToken,
    };
  } catch {
    return { url: configuredOrigin ?? "", serviceToken };
  }
}

export function publicationErrorResponse(error: unknown): Response {
  if (error instanceof PublicationInputError) {
    const copy = inputErrorCopy(error);
    return jsonResponse({
      error: "vm_publication_invalid_request",
      message: copy.message,
      action: copy.action,
      reason: error.reason,
      details: { field: error.field },
    }, 400);
  }
  if (error instanceof PublicationNotFoundError) {
    return jsonResponse({
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
    const copy = conflictCopy(error.reason);
    return jsonResponse({
      error: "vm_publication_conflict",
      message: copy.message,
      action: copy.action,
      reason: error.reason,
    }, copy.status);
  }
  if (error instanceof PublicationAccountDeletionBlockedError) {
    return jsonResponse({
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
      },
    });
  }
  if (error instanceof PublicationConfigurationError) {
    return jsonResponse({
      error: "vm_publication_not_configured",
      message: error.reason === "invalid_auth_origin"
        ? "The Cloud VM domain sign-in origin is not a valid HTTPS URL."
        : "Protected Cloud VM domains are not configured on this CMUX deployment.",
      action: error.reason === "invalid_auth_origin"
        ? "Set CMUX_VM_PUBLICATION_AUTH_ORIGIN to the canonical HTTPS CMUX web origin."
        : "Set CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET before using personal or team access.",
      reason: error.reason,
    }, 503);
  }
  if (error instanceof VmPublicationProviderError) {
    return jsonResponse({
      error: "vm_publication_provider_unavailable",
      message: "The Cloud VM domain service could not complete this change.",
      action: "Run `cmux cloud domains list`; verify any provisioning entry, or retry if none exists. Contact support if it keeps failing.",
      retryable: true,
    }, 502);
  }
  if (error instanceof PublicationInvariantError || error instanceof PublicationDatabaseError) {
    return jsonResponse({
      error: "vm_publication_internal_error",
      message: "CMUX could not finish the Cloud VM domain change safely.",
      action: "Retry once. If it keeps failing, contact support with the publication id.",
    }, 500);
  }
  return jsonResponse({
    error: "vm_publication_internal_error",
    message: "Cloud VM publication failed unexpectedly.",
    action: "Retry once. If it keeps failing, contact support.",
  }, 500);
}

function inputErrorCopy(error: PublicationInputError): {
  readonly message: string;
  readonly action: string;
} {
  switch (error.reason) {
    case "invalid_hostname":
      return {
        message: "hostname must be one exact DNS hostname.",
        action: "Pass a hostname such as preview.example.com, without a scheme, port, path, or wildcard.",
      };
    case "generated_hostname_reserved":
      return {
        message: "style.dev names are generated by CMUX and cannot be selected with --domain.",
        action: "Omit --domain for a generated name, or pass a customer-owned hostname.",
      };
    case "invalid_port":
      return {
        message: "port must be an integer between 1 and 65535.",
        action: "Pass the HTTP port listening inside the Cloud VM.",
      };
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

function conflictCopy(reason: PublicationConflictError["reason"]): {
  readonly message: string;
  readonly action: string;
  readonly status: number;
} {
  switch (reason) {
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
