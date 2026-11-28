import { coderouterControlRoute } from "../../../../../services/coderouter/requestTelemetry";
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthFailure,
} from "../../../../../services/coderouter/routeTokenAuth";
import { revokeApiKey } from "../../../../../services/coderouter/repository";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";

const JSON_HEADERS = { "cache-control": "no-store", "content-type": "application/json" };

export type ApiKeySelfDependencies = {
  readonly authenticate: typeof authenticateRequestRouteToken;
  readonly revoke: typeof revokeApiKey;
};

const defaultDependencies: ApiKeySelfDependencies = {
  authenticate: authenticateRequestRouteToken,
  revoke: revokeApiKey,
};

export function makeApiKeySelfHandlers(dependencies: ApiKeySelfDependencies = defaultDependencies) {
  return {
    GET: (request: Request) => handleGet(dependencies, request),
    DELETE: (request: Request) => handleDelete(dependencies, request),
  };
}

const handlers = makeApiKeySelfHandlers();
export const GET = coderouterControlRoute("session", "/api/coderouter/api-keys/self", handlers.GET);
export const DELETE = coderouterControlRoute("session", "/api/coderouter/api-keys/self", handlers.DELETE);

async function handleGet(dependencies: ApiKeySelfDependencies, request: Request): Promise<Response> {
  const auth = await dependencies.authenticate(request);
  if (!auth.ok) return unauthorized(auth.reason);
  if (!auth.identity.apiKeyId) {
    return Response.json({ error: "api_key_required" }, { status: 403, headers: JSON_HEADERS });
  }
  return Response.json(
    { teamId: auth.identity.teamId, apiKeyId: auth.identity.apiKeyId },
    { headers: JSON_HEADERS },
  );
}

async function handleDelete(dependencies: ApiKeySelfDependencies, request: Request): Promise<Response> {
  const auth = await dependencies.authenticate(request);
  if (!auth.ok) return unauthorized(auth.reason);
  const apiKeyId = auth.identity.apiKeyId;
  if (!apiKeyId) {
    return Response.json({ error: "api_key_required" }, { status: 403, headers: JSON_HEADERS });
  }
  const revoked = await dependencies.revoke(auth.identity.teamId, apiKeyId);
  if (revoked) {
    captureCoderouterEvent({
      event: "coderouter_api_key_revoked",
      userId: auth.identity.stackUserId,
      teamId: auth.identity.teamId,
      properties: { self: true },
    });
  }
  return new Response(null, { status: 204, headers: JSON_HEADERS });
}

function unauthorized(_reason: RouteTokenAuthFailure): Response {
  return Response.json(
    { error: "unauthorized", retryable: false },
    { status: 401, headers: JSON_HEADERS },
  );
}
