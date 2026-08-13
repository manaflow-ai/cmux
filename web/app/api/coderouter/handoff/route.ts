import { env } from "../../../env";
import { hasActiveCoderouterSubscription } from "../../../../services/billing/pro";
import {
  issueCoderouterHandoffLease,
} from "../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";
import { captureCoderouterError } from "../../../../services/errors";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "../../../../services/coderouter/observability";
import {
  jsonHandoffResponse,
  isJsonContentType,
  defaultCoderouterHandoffRateLimiter,
  parseEmptyHandoffBody,
  rateLimitResponse,
  readBoundedBody,
  isBoundedNativeStackRequest,
  validTeamSelectorHeaders,
  type HandoffRateLimiter,
} from "./_shared";

type HandoffMintDependencies = {
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly hasActiveEntitlement: typeof hasActiveCoderouterSubscription;
  readonly issueLease: typeof issueCoderouterHandoffLease;
  readonly hostedProRequired: () => boolean;
  readonly rateLimit: HandoffRateLimiter;
  readonly now?: () => Date;
};

const defaultRateLimit = defaultCoderouterHandoffRateLimiter;

const defaultDependencies: HandoffMintDependencies = {
  resolveContext: resolveCodeRouterRequestContext,
  hasActiveEntitlement: hasActiveCoderouterSubscription,
  issueLease: issueCoderouterHandoffLease,
  hostedProRequired: () => env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
  rateLimit: defaultRateLimit,
  now: () => new Date(),
};

export const POST = makeCoderouterHandoffPostHandler();

export function makeCoderouterHandoffPostHandler(
  dependencies: HandoffMintDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    const rateLimited = rateLimitResponse(await dependencies.rateLimit(request));
    if (rateLimited) return rateLimited;

    // This endpoint deliberately does not accept the browser cookie path.
    // Stack's native access/refresh pair is the authorization assumption
    // defined by docs/coderouter-handoff-protocol.md.
    if (
      !isBoundedNativeStackRequest(request) ||
      !validTeamSelectorHeaders(request)
    ) {
      captureCoderouterEvent({
        event: "coderouter_handoff_rejected",
        properties: {
          surface: "mint",
          reason: "missing_native_auth",
        },
      });
      return jsonHandoffResponse({ error: "unauthorized" }, 401);
    }

    const body = await readBoundedBody(request);
    if (!body.ok) return jsonHandoffResponse(
      { error: body.status === 413 ? "payload_too_large" : "invalid_request" },
      body.status,
    );
    if (
      body.body.trim() &&
      (!isJsonContentType(request) || !parseEmptyHandoffBody(body.body))
    ) {
      return jsonHandoffResponse({ error: "invalid_request" }, 400);
    }

    let resolved;
    try {
      resolved = await dependencies.resolveContext(request, "use");
    } catch (error) {
      captureCoderouterError(error, {
        operation: "resolve_handoff_mint_context",
        route: "/api/coderouter/handoff",
      });
      return jsonHandoffResponse(
        {
          error: "authorization_unavailable",
          message: "CodeRouter authorization is temporarily unavailable.",
          retryable: true,
        },
        503,
        { "retry-after": "5" },
      );
    }
    if (!resolved.ok) return resolved.response;
    if (!resolved.value.team.use) {
      return jsonHandoffResponse({ error: "forbidden" }, 403);
    }

    if (dependencies.hostedProRequired()) {
      try {
        if (
          !(await dependencies.hasActiveEntitlement(
            resolved.value.user.id,
            resolved.value.team.teamId,
          ))
        ) {
          return jsonHandoffResponse(
            {
              error: "pro_required",
              message:
                "Hosted coderouter requires cmux Pro or Team.",
              retryable: false,
            },
            402,
          );
        }
      } catch (error) {
        captureCoderouterError(error, {
          operation: "resolve_handoff_entitlement",
          route: "/api/coderouter/handoff",
        });
        return jsonHandoffResponse(
          {
            error: "entitlement_unavailable",
            message: "CodeRouter entitlement could not be verified.",
            retryable: true,
          },
          503,
          { "retry-after": "5" },
        );
      }
    }

    let issued: Awaited<ReturnType<typeof issueCoderouterHandoffLease>>;
    try {
      issued = await dependencies.issueLease(
        resolved.value.team.teamId,
        resolved.value.user.id,
        dependencies.now?.() ?? new Date(),
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, {
        operation: "issue_handoff_lease",
      });
      return jsonHandoffResponse(
        {
          error: "handoff_unavailable",
          message: "CodeRouter handoff could not be created.",
          retryable: true,
        },
        503,
        { "retry-after": "5" },
      );
    }

    // Never include the lease in telemetry. The value is returned only in this
    // no-store response and is represented in storage by its digest.
    captureCoderouterEvent({
      event: "coderouter_handoff_lease_issued",
      userId: resolved.value.user.id,
      teamId: resolved.value.team.teamId,
      properties: { authorization_mode: "native_stack" },
    });
    addCoderouterBreadcrumb("handoff", "Handoff lease issued");
    return jsonHandoffResponse({
      teamId: resolved.value.team.teamId,
      lease: issued.lease,
      expiresAt: issued.expiresAt.toISOString(),
    });
  };
}
