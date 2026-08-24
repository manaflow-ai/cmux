import { env } from "../../../env";
import {
  CODEROUTER_FREE_ACCOUNT_LIMIT,
  coderouterEntitlement,
} from "../../../../services/coderouter/entitlement";
import {
  authenticateRouteToken,
  issueRouteToken,
  revokeRouteToken,
} from "../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";
import { captureCoderouterError } from "../../../../services/errors";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../services/coderouter/observability";


type SessionDependencies = {
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly entitlement: typeof coderouterEntitlement;
  readonly issueToken: typeof issueRouteToken;
  readonly hostedProRequired: () => boolean;
};

const defaultDependencies: SessionDependencies = {
  resolveContext: resolveCodeRouterRequestContext,
  entitlement: coderouterEntitlement,
  issueToken: issueRouteToken,
  hostedProRequired: () => env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
};

export const POST = makeCoderouterSessionPostHandler();

export const GET = makeCoderouterSessionGetHandler();

export function makeCoderouterSessionGetHandler(
  authenticate: typeof authenticateRouteToken = authenticateRouteToken,
) {
  return async function GET(request: Request): Promise<Response> {
    const authorization = request.headers.get("authorization")?.trim() ?? "";
    const token = /^Bearer[ \t]+(.+)$/i.exec(authorization)?.[1]?.trim();
    const identity = token ? await authenticate(token) : null;
    if (!identity) {
      addCoderouterBreadcrumb(
        "auth",
        "Route session validation rejected",
        {},
        "warning",
      );
      captureCoderouterEvent({
        event: "coderouter_auth_rejected",
        properties: {
          surface: "session_validation",
          reason: token ? "invalid_route_token" : "missing_route_token",
        },
      });
      return Response.json(
        {
          error: "unauthorized",
          message:
            "Your coderouter session expired or was revoked. Run `cr login` and retry.",
          retryable: false,
        },
        { status: 401, headers: { "cache-control": "no-store" } },
      );
    }
    return new Response(null, {
      status: 204,
      headers: { "cache-control": "no-store" },
    });
  };
}

export function makeCoderouterSessionPostHandler(
  dependencies: SessionDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveContext(request, "use");
    if (!resolved.ok) return resolved.response;
    const userId = resolved.value.user.id;
    let entitlementBasis = "ungated";
    if (dependencies.hostedProRequired()) {
      try {
        const entitlement = await dependencies.entitlement(
          userId,
          resolved.value.team.teamId,
        );
        entitlementBasis = entitlement.basis;
        if (!entitlement.allowed) {
          return Response.json(
            {
              error: "pro_required",
              message:
                `Free hosted coderouter covers up to ${CODEROUTER_FREE_ACCOUNT_LIMIT} connected accounts; ` +
                `this team has ${entitlement.accountCount}. ` +
                "Upgrade to cmux Pro or Team, remove accounts, or connect a self-hosted server.",
              retryable: false,
            },
            {
              status: 402,
              headers: { "cache-control": "no-store" },
            },
          );
        }
      } catch (error) {
        captureCoderouterError(error, {
          operation: "resolve_hosted_entitlement",
          route: "/api/coderouter/session",
        });
        return Response.json(
          {
            error: "entitlement_unavailable",
            message:
              "coderouter could not verify your Pro entitlement. Nothing was charged or changed; retry shortly.",
            retryable: true,
          },
          {
            status: 503,
            headers: { "cache-control": "no-store" },
          },
        );
      }
    }
    let issued;
    try {
      issued = await dependencies.issueToken(
        resolved.value.team.teamId,
        userId,
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, {
        operation: "issue_route_session",
      });
      return Response.json(
        {
          error: "session_unavailable",
          message:
            "coderouter could not create a route session. Retry shortly; no account credentials were changed.",
          retryable: true,
        },
        {
          status: 503,
          headers: { "cache-control": "no-store", "retry-after": "5" },
        },
      );
    }
    captureCoderouterEvent({
      event: "coderouter_route_session_issued",
      userId,
      teamId: resolved.value.team.teamId,
      properties: {
        hosted_pro_required: dependencies.hostedProRequired(),
        entitlement_basis: entitlementBasis,
      },
    });
    addCoderouterBreadcrumb("session", "Route session issued");
    return Response.json(
      {
        teamId: resolved.value.team.teamId,
        token: issued.token,
        expiresAt: issued.expiresAt.toISOString(),
        openaiBaseUrl: new URL("/v1", request.url)
          .toString()
          .replace(/\/$/, ""),
      },
      { headers: { "cache-control": "no-store" } },
    );
  };
}

export async function DELETE(request: Request): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "use");
  if (!resolved.ok) return resolved.response;
  const routeToken = request.headers.get("x-coderouter-route-token")?.trim();
  if (!routeToken) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  await revokeRouteToken(resolved.value.team.teamId, routeToken);
  captureCoderouterEvent({
    event: "coderouter_route_session_revoked",
    userId: resolved.value.user.id,
    teamId: resolved.value.team.teamId,
  });
  addCoderouterBreadcrumb("session", "Route session revoked");
  return new Response(null, {
    status: 204,
    headers: { "cache-control": "no-store" },
  });
}
