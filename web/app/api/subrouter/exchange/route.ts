import { resolveSubrouterRequestContext } from "../../../../services/subrouter/requestContext";
import { subrouterErrorResponse } from "../../../../services/subrouter/routeHelpers";


export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveSubrouterRequestContext(request, {
    allowCookie: false,
  });
  if (!resolved.ok) return resolved.response;

  try {
    const tenant = await resolved.value.client.exchangeTeam(
      resolved.value.accessToken,
      resolved.value.team,
    );
    return Response.json(tenant, {
      headers: { "cache-control": "no-store" },
    });
  } catch (error) {
    return subrouterErrorResponse(error);
  }
}
