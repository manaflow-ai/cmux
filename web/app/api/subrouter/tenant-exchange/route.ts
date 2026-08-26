import { resolveSubrouterRequestContext } from "../../../../services/subrouter/requestContext";
import { subrouterErrorResponse } from "../../../../services/subrouter/routeHelpers";
import { env } from "../../../env";


export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveSubrouterRequestContext(request, {
    permission: "use-or-manage",
    allowCookie: false,
  });
  if (!resolved.ok) return resolved.response;

  try {
    const controlToken = env.SUBROUTER_STACK_TENANT_DELETE_TOKEN?.trim();
    const hostedUrl = env.SUBROUTER_HOSTED_URL?.trim().replace(
      /\/+$/,
      "",
    );
    if (!controlToken || !hostedUrl) {
      return Response.json(
        { error: "service_unavailable" },
        { status: 503 },
      );
    }
    const capabilities = [
      ...(resolved.value.team.manageAccounts ? ["manage_accounts"] : []),
      ...(resolved.value.team.use ? ["use"] : []),
    ];
    const upstream = await fetch(`${hostedUrl}/_subrouter/auth/stack`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${resolved.value.accessToken}`,
        "content-type": "application/json",
        "x-subrouter-stack-control-token": controlToken,
      },
      body: JSON.stringify({
        capabilities,
        teamId: resolved.value.team.teamId,
        teamName: resolved.value.team.teamName,
      }),
      cache: "no-store",
    });
    const body = await upstream.text();
    if (!upstream.ok) {
      return new Response(body, {
        status: upstream.status,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    const tenant: unknown = JSON.parse(body);
    return Response.json(tenant, {
      headers: { "cache-control": "no-store" },
    });
  } catch (error) {
    return subrouterErrorResponse(error);
  }
}
