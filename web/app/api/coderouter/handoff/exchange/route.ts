import { env } from "../../../../env";
import { hasActiveCoderouterSubscription } from "../../../../../services/billing/pro";
import {
  exchangeCoderouterHandoffLease,
} from "../../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";
import {
  exchangeCoderouterHandoff,
  mapHandoffWorkflowError,
  runHandoffWorkflow,
  type HandoffExchangeDependencies as WorkflowExchangeDependencies,
  type HandoffProtocol,
} from "../../../../../services/coderouter/handoffWorkflow";
import { reportCoderouterFailure } from "../../../../../services/coderouter/observability";
import {
  coderouterOpenaiBaseUrl,
  defaultCoderouterHandoffRateLimiter,
  hasCoderouterHandoffTeamSelector,
  hasNativeStackAuthHeaders,
  isBoundedNativeStackRequest,
  isJsonContentType,
  jsonHandoffResponse,
  parseEmptyHandoffBody,
  parseHandoffLeaseBody,
  rateLimitResponse,
  readBoundedBody,
  validTeamSelectorHeaders,
  type HandoffRateLimiter,
} from "../_shared";

type HandoffExchangeDependencies = Omit<
  WorkflowExchangeDependencies,
  "protocol"
> & {
  readonly rateLimit: HandoffRateLimiter;
};

const defaultDependencies: HandoffExchangeDependencies = {
  exchangeLease: exchangeCoderouterHandoffLease,
  resolveContext: resolveCodeRouterRequestContext,
  hasActiveEntitlement: hasActiveCoderouterSubscription,
  hostedProRequired: () => env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
  rateLimit: defaultCoderouterHandoffRateLimiter,
  publicOrigin: () => env.CMUX_CODEROUTER_PUBLIC_ORIGIN,
  now: () => new Date(),
};

function protocolFor(
  dependencies: HandoffExchangeDependencies,
): HandoffProtocol {
  return {
    rateLimit: dependencies.rateLimit,
    hasNativeStackAuthHeaders,
    isBoundedNativeStackRequest,
    validTeamSelectorHeaders,
    hasTeamSelector: hasCoderouterHandoffTeamSelector,
    coderouterOpenaiBaseUrl,
    readBoundedBody,
    isJsonContentType,
    parseEmptyHandoffBody,
    parseHandoffLeaseBody,
  };
}

export const POST = makeCoderouterHandoffExchangePostHandler();

export function makeCoderouterHandoffExchangePostHandler(
  dependencies: HandoffExchangeDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    try {
      const result = await runHandoffWorkflow(
        exchangeCoderouterHandoff(
          request,
          undefined,
          {
            protocol: protocolFor(dependencies),
            exchangeLease: dependencies.exchangeLease,
            resolveContext: dependencies.resolveContext,
            hasActiveEntitlement: dependencies.hasActiveEntitlement,
            hostedProRequired: dependencies.hostedProRequired,
            publicOrigin: dependencies.publicOrigin,
            now: dependencies.now,
          },
        ),
      );
      if (result._tag === "Left") {
        return mapHandoffWorkflowError(
          result.left,
          jsonHandoffResponse,
          rateLimitResponse,
        );
      }
      return jsonHandoffResponse({
        teamId: result.right.teamId,
        token: result.right.token,
        expiresAt: result.right.expiresAt.toISOString(),
        openaiBaseUrl: result.right.openaiBaseUrl,
      });
    } catch (error) {
      reportCoderouterFailure("rds", error, {
        operation: "handoff_exchange_workflow",
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
  };
}
