import { env } from "../../../../env";
import { hasActiveCoderouterSubscription } from "../../../../../services/billing/pro";
import {
  exchangeCoderouterHandoffLease,
  type CodeRouterHandoffAuthorizer,
  type CodeRouterHandoffEntitlementDb,
  type CodeRouterHandoffIdentity,
} from "../../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";
import { captureCoderouterError } from "../../../../../services/errors";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "../../../../../services/coderouter/observability";
import {
  hasNativeStackAuthHeaders,
  isBoundedNativeStackRequest,
  coderouterOpenaiBaseUrl,
  defaultCoderouterHandoffRateLimiter,
  hasCoderouterHandoffTeamSelector,
  isJsonContentType,
  jsonHandoffResponse,
  parseHandoffLeaseBody,
  rateLimitResponse,
  readBoundedBody,
  validTeamSelectorHeaders,
  type HandoffRateLimiter,
} from "../_shared";

type HandoffExchangeDependencies = {
  readonly exchangeLease: typeof exchangeCoderouterHandoffLease;
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly hasActiveEntitlement: typeof hasActiveCoderouterSubscription;
  readonly hostedProRequired: () => boolean;
  readonly rateLimit: HandoffRateLimiter;
  readonly publicOrigin?: () => string | undefined;
  readonly now?: () => Date;
};

const defaultRateLimit = defaultCoderouterHandoffRateLimiter;

const defaultDependencies: HandoffExchangeDependencies = {
  exchangeLease: exchangeCoderouterHandoffLease,
  resolveContext: resolveCodeRouterRequestContext,
  hasActiveEntitlement: hasActiveCoderouterSubscription,
  hostedProRequired: () => env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
  rateLimit: defaultRateLimit,
  publicOrigin: () => env.CMUX_CODEROUTER_PUBLIC_ORIGIN,
  now: () => new Date(),
};

export const POST = makeCoderouterHandoffExchangePostHandler();

export function makeCoderouterHandoffExchangePostHandler(
  dependencies: HandoffExchangeDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    const rateLimited = rateLimitResponse(await dependencies.rateLimit(request));
    if (rateLimited) return rateLimited;

    const body = await readBoundedBody(request);
    if (!body.ok) return jsonHandoffResponse(
      { error: body.status === 413 ? "payload_too_large" : "invalid_request" },
      body.status,
    );
    if (!isJsonContentType(request)) {
      return jsonHandoffResponse({ error: "invalid_request" }, 400);
    }
    const lease = parseHandoffLeaseBody(body.body);
    if (!lease) return jsonHandoffResponse({ error: "invalid_request" }, 400);
    // This is the only point at which the opaque value enters the service
    // layer. It is never put into telemetry or an error context.

    if (
      !hasNativeStackAuthHeaders(request) &&
      request.headers.get("cookie") !== null
    ) {
      // A browser cookie is neither needed nor accepted for bearer exchange.
      // Rejecting it avoids making a same-origin browser page look like a
      // supported CodeRouter native caller.
      return jsonHandoffResponse({ error: "unauthorized" }, 401);
    }

    const hostedProRequired = dependencies.hostedProRequired();
    let expectedIdentity: CodeRouterHandoffIdentity = {};
    if (hasNativeStackAuthHeaders(request)) {
      // Optional native confirmation binds the exchange to the same principal
      // without making Stack credentials mandatory for the handoff recipient.
      // A malformed pair never falls through to a browser cookie.
      if (
        !isBoundedNativeStackRequest(request) ||
        !validTeamSelectorHeaders(request)
      ) {
        return jsonHandoffResponse({ error: "unauthorized" }, 401);
      }

      let resolved;
      try {
        resolved = await dependencies.resolveContext(request, "use");
      } catch (error) {
        captureCoderouterError(error, {
          operation: "resolve_handoff_exchange_context",
          route: "/api/coderouter/handoff/exchange",
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

      if (hostedProRequired) {
        try {
          if (
            !(await dependencies.hasActiveEntitlement(
              resolved.value.user.id,
              resolved.value.team.teamId,
            ))
          ) {
            return jsonHandoffResponse(
              { error: "pro_required", retryable: false },
              402,
            );
          }
        } catch (error) {
          captureCoderouterError(error, {
            operation: "resolve_handoff_exchange_entitlement",
            route: "/api/coderouter/handoff/exchange",
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
      expectedIdentity = {
        teamId: resolved.value.team.teamId,
        stackUserId: resolved.value.user.id,
      };
    } else if (
      !validTeamSelectorHeaders(request) ||
      hasCoderouterHandoffTeamSelector(request)
    ) {
      // The possession-only exchange has no meaningful team selector. Reject
      // one rather than silently pretending it constrains the lease.
      return jsonHandoffResponse({ error: "invalid_request" }, 400);
    }

    // The repository authorizer rechecks the lease's stored principal
    // immediately before its atomic claim, closing the
    // mint-versus-cancellation window for both possession-only and optional
    // native-confirmed exchanges.
    const authorizeLease: CodeRouterHandoffAuthorizer | undefined =
      hostedProRequired
        ? async (identity, db: CodeRouterHandoffEntitlementDb) =>
          await dependencies.hasActiveEntitlement(
            identity.stackUserId,
            identity.teamId,
            db,
          )
        : undefined;

    // Resolve the public data-plane origin before claiming the lease. A
    // missing production configuration must not burn a valid one-time lease.
    const openaiBaseUrl = coderouterOpenaiBaseUrl(
      request,
      dependencies.publicOrigin?.(),
    );
    if (!openaiBaseUrl) {
      reportCoderouterFailure("configuration", new Error("handoff origin unavailable"), {
        operation: "resolve_handoff_origin",
      });
      return jsonHandoffResponse(
        {
          error: "handoff_unavailable",
          message: "CodeRouter handoff could not be exchanged.",
          retryable: true,
        },
        503,
        { "retry-after": "5" },
      );
    }

    let exchanged;
    try {
      exchanged = await dependencies.exchangeLease(
        lease,
        dependencies.now?.() ?? new Date(),
        expectedIdentity,
        authorizeLease,
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, {
        operation: "exchange_handoff_lease",
      });
      return jsonHandoffResponse(
        {
          error: "handoff_unavailable",
          message: "CodeRouter handoff could not be exchanged.",
          retryable: true,
        },
        503,
        { "retry-after": "5" },
      );
    }
    if (!exchanged) {
      // Do not distinguish unknown, expired, consumed, or identity-mismatched
      // leases. That distinction would turn this bearer endpoint into a
      // replay/validity oracle.
      captureCoderouterEvent({
        event: "coderouter_handoff_rejected",
        properties: {
          surface: "exchange",
          reason: "expired_or_consumed",
        },
      });
      return jsonHandoffResponse(
        { error: "invalid_handoff_lease", retryable: false },
        401,
      );
    }

    captureCoderouterEvent({
      event: "coderouter_handoff_lease_exchanged",
      userId: exchanged.stackUserId,
      teamId: exchanged.teamId,
      properties: {
        authorization_mode: Object.keys(expectedIdentity).length > 0
          ? "native_confirmation"
          : "lease",
      },
    });
    addCoderouterBreadcrumb("handoff", "Handoff lease exchanged");
    return jsonHandoffResponse({
      teamId: exchanged.teamId,
      token: exchanged.token,
      expiresAt: exchanged.expiresAt.toISOString(),
      openaiBaseUrl,
    });
  };
}
