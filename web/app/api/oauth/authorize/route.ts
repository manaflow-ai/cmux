// Records the decision from the `/authorize/mcp` consent form and redirects
// back to the MCP client with a code (or `access_denied`).

import {
  approveConsent,
  approvedScopes,
  authorizationParams,
  consentTeamId,
  consentUserFromRequest,
  denyConsent,
  validateConsentRequest,
} from "../../../../services/mcp/oauthConsent";
import { authorizationRedirect, MCP_AUTHORIZE_PATH } from "../../../../services/mcp/oauth";
import { mcpIssuer, mcpPublicOrigin } from "../../../../services/mcp/oauthRoutes";

function seeOther(location: string): Response {
  return new Response(null, { status: 303, headers: { location, "cache-control": "no-store" } });
}

function plainError(status: number, message: string): Response {
  return new Response(message, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

export async function POST(request: Request): Promise<Response> {
  const origin = mcpIssuer(request);
  // The consent cookie session must not be usable from another site.
  if (request.headers.get("origin") !== mcpPublicOrigin(request)) return plainError(403, "Cross-site authorization requests are refused.");
  const form = new URLSearchParams(await request.text());
  const params = authorizationParams(form);
  const validated = await validateConsentRequest(params, origin);
  if (!validated.ok) {
    if (!validated.redirectable || !validated.redirectUri) return plainError(400, validated.error.description);
    return seeOther(authorizationRedirect(validated.redirectUri, origin, {
      error: validated.error.error,
      error_description: validated.error.description,
      state: validated.state,
    }));
  }
  const user = await consentUserFromRequest(request);
  if (!user) return seeOther(`${MCP_AUTHORIZE_PATH}?${params.toString()}`);
  if (form.get("decision") !== "approve") return seeOther(denyConsent(validated.request, origin));
  const teamId = consentTeamId(user, form.get("team_id"));
  if (teamId === undefined) return plainError(403, "Choose one of your teams.");
  const scopes = approvedScopes(form, validated.request);
  if (scopes.length === 0) return seeOther(denyConsent(validated.request, origin));
  return seeOther(await approveConsent(validated.request, user, teamId, scopes, origin));
}
