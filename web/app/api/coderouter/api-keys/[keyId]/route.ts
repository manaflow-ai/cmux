import { coderouterControlRoute } from "../../../../../services/coderouter/requestTelemetry";
import { revokeApiKey } from "../../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const DELETE = coderouterControlRoute(
  "session",
  "/api/coderouter/api-keys/[keyId]",
  handleDelete,
);

async function handleDelete(
  request: Request,
  context: { params: Promise<{ keyId: string }> },
): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request);
  if (!resolved.ok) return resolved.response;
  if (!resolved.value.team.manageAccounts) {
    return Response.json({ error: "forbidden" }, { status: 403 });
  }
  const { keyId } = await context.params;
  if (!UUID.test(keyId)) return Response.json({ error: "invalid_request" }, { status: 400 });
  const revoked = await revokeApiKey(resolved.value.team.teamId, keyId);
  if (!revoked) return Response.json({ error: "not_found" }, { status: 404 });
  captureCoderouterEvent({
    event: "coderouter_api_key_revoked",
    userId: resolved.value.user.id,
    teamId: resolved.value.team.teamId,
    properties: { self: false },
  });
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}
