import { bearerToken, cacheDeadline, tokenExpiryMs, verifyRequest, type AuthEnv } from "./auth";
import { VIEW_AUTH_MS, parseWorkspaceScope, viewerIdentity, workspaceRoom } from "./workspacePresence";
import type { WorkspacePresence } from "./workspacePresenceDo";

export async function workspacePresenceRoute(request: Request, env: AuthEnv & {
  WORKSPACE_PRESENCE: DurableObjectNamespace<WorkspacePresence>;
}): Promise<Response> {
  if (request.method !== "GET") return Response.json({ error: "method_not_allowed" }, { status: 405 });
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return Response.json({ error: "websocket_required" }, { status: 400 });
  const raw = new URL(request.url).searchParams.get("scope");
  if (!raw || raw.length > 1024) return Response.json({ error: "invalid_scope" }, { status: 400 });
  let scope;
  try { scope = parseWorkspaceScope(JSON.parse(raw)); } catch { scope = null; }
  if (!scope) return Response.json({ error: "invalid_scope" }, { status: 400 });
  const user = await verifyRequest(request, env);
  if (!user) return Response.json({ error: "unauthorized" }, { status: 401 });
  const room = workspaceRoom(scope, user);
  if (!room) return Response.json({ error: "forbidden" }, { status: 403 });
  const token = bearerToken(request);
  const expiresAt = cacheDeadline(Date.now(), token ? tokenExpiryMs(token) : null, VIEW_AUTH_MS);
  // Rebuild headers: caller-supplied identity/expiry cannot reach the object.
  const headers = new Headers({ upgrade: "websocket", "x-workspace-scope": JSON.stringify(scope),
    "x-workspace-viewer": JSON.stringify(viewerIdentity(user)), "x-workspace-expires": String(expiresAt) });
  return env.WORKSPACE_PRESENCE.get(env.WORKSPACE_PRESENCE.idFromName(room))
    .fetch(new Request(request.url, { headers }));
}
