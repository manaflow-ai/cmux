import { env } from "../../../env";
import { hasActiveStripeProSubscription } from "../../../../services/billing/pro";
import {
  authenticateRouteToken,
  issueRouteToken,
  revokeRouteToken,
} from "../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";
import { captureCoderouterError } from "../../../../services/errors";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type SessionDependencies = {
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly hasActivePro: typeof hasActiveStripeProSubscription;
  readonly issueToken: typeof issueRouteToken;
  readonly hostedProRequired: () => boolean;
};

const defaultDependencies: SessionDependencies = {
  resolveContext: resolveCodeRouterRequestContext,
  hasActivePro: hasActiveStripeProSubscription,
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
    if (!token || !await authenticate(token)) {
      return Response.json(
        { error: "unauthorized" },
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
    if (dependencies.hostedProRequired()) {
      try {
        if (!await dependencies.hasActivePro(userId)) {
          return Response.json(
            { error: "pro_required" },
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
          { error: "entitlement_unavailable" },
          {
            status: 503,
            headers: { "cache-control": "no-store" },
          },
        );
      }
    }
    const issued = await dependencies.issueToken(
      resolved.value.team.teamId,
      userId,
    );
    return Response.json(
      {
        teamId: resolved.value.team.teamId,
        token: issued.token,
        expiresAt: issued.expiresAt.toISOString(),
        openaiBaseUrl: new URL("/v1", request.url).toString().replace(/\/$/, ""),
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
  return new Response(null, {
    status: 204,
    headers: { "cache-control": "no-store" },
  });
}
