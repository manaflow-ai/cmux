import { env } from "../../../env";
import { hasActiveCoderouterSubscription } from "../../../../services/billing/pro";
import { issueCoderouterHandoffLease } from "../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";
import {
  mapHandoffWorkflowError,
  mintCoderouterHandoff,
  runHandoffWorkflow,
  type HandoffMintDependencies as WorkflowMintDependencies,
  type HandoffProtocol,
} from "../../../../services/coderouter/handoffWorkflow";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";
import {
  coderouterOpenaiBaseUrl,
  defaultCoderouterHandoffRateLimiter,
  isBoundedNativeStackRequest,
  isJsonContentType,
  hasCoderouterHandoffTeamSelector,
  jsonHandoffResponse,
  parseEmptyHandoffBody,
  parseHandoffLeaseBody,
  rateLimitResponse,
  readBoundedBody,
  validTeamSelectorHeaders,
  hasNativeStackAuthHeaders,
  type HandoffRateLimiter,
} from "./_shared";

type HandoffMintDependencies = Omit<
  WorkflowMintDependencies,
  "protocol"
> & {
  readonly rateLimit: HandoffRateLimiter;
};

const defaultDependencies: HandoffMintDependencies = {
  resolveContext: resolveCodeRouterRequestContext,
  hasActiveEntitlement: hasActiveCoderouterSubscription,
  issueLease: issueCoderouterHandoffLease,
  hostedProRequired: () => env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
  rateLimit: defaultCoderouterHandoffRateLimiter,
  now: () => new Date(),
};

function protocolFor(
  dependencies: HandoffMintDependencies,
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

export const POST = makeCoderouterHandoffPostHandler();

export function makeCoderouterHandoffPostHandler(
  dependencies: HandoffMintDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    try {
      const result = await runHandoffWorkflow(
        mintCoderouterHandoff(request, {
          protocol: protocolFor(dependencies),
          resolveContext: dependencies.resolveContext,
          hasActiveEntitlement: dependencies.hasActiveEntitlement,
          issueLease: dependencies.issueLease,
          hostedProRequired: dependencies.hostedProRequired,
          now: dependencies.now,
        }),
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
        lease: result.right.lease,
        expiresAt: result.right.expiresAt.toISOString(),
      });
    } catch (error) {
      // The workflow maps expected failures into typed outcomes. This catch is
      // only for an unexpected defect; report a low-cardinality operation and
      // never include request headers, body, or lease values.
      reportCoderouterFailure("rds", error, {
        operation: "handoff_mint_workflow",
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
  };
}
