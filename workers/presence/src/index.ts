// cmux device presence service — worker entry.
//
// Routes (all JSON unless noted):
//   GET  /healthz                         liveness, no auth
//   POST /v1/presence/heartbeat           announce an app instance (15s cadence)
//   GET  /v1/presence/snapshot            one-shot presence map
//   GET  /v1/presence/subscribe           WebSocket upgrade or SSE stream:
//                                         snapshot first, then online/offline/seen
//
// Auth on every /v1 route: `Authorization: Bearer <Stack access token>` plus
// optional `X-Cmux-Team-Id` / `?teamId=` team scoping, verified in auth.ts the
// same way web/app/api verifies native callers. The worker resolves the team,
// derives the per-team Durable Object from the VERIFIED team id, and forwards;
// the DO never sees unauthenticated input.

import {
  bearerToken,
  cacheDeadline,
  requestedTeamIdFromRequest,
  resolveTeamId,
  tokenExpiryMs,
  verifyRequest,
  type AuthedUser,
  type AuthEnv,
} from "./auth";
import { MAX_SUBSCRIBE_AGE_MS, TeamPresence } from "./do";
import { parseHeartbeat, readBoundedJson } from "./validate";

export { TeamPresence };

export interface Env extends AuthEnv {
  TEAM_PRESENCE: DurableObjectNamespace<TeamPresence>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function unauthorized(): Response {
  return json({ error: "unauthorized" }, 401);
}

async function resolveTeamOr403(
  request: Request,
  env: Env,
): Promise<
  | { ok: true; teamId: string; user: AuthedUser; stub: DurableObjectStub<TeamPresence> }
  | { ok: false; response: Response }
> {
  const user = await verifyRequest(request, env);
  if (!user) return { ok: false, response: unauthorized() };
  const team = resolveTeamId(requestedTeamIdFromRequest(request), user);
  if (!team.ok) return { ok: false, response: json({ error: "team_not_found" }, 403) };
  const stub = env.TEAM_PRESENCE.get(env.TEAM_PRESENCE.idFromName(team.teamId));
  return { ok: true, teamId: team.teamId, user, stub };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-presence" });
    }

    if (url.pathname === "/v1/presence/heartbeat") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const team = await resolveTeamOr403(request, env);
      if (!team.ok) return team.response;
      const body = await readBoundedJson(request);
      if (!body.ok) return json({ error: "invalid_request" }, body.status);
      const parsed = parseHeartbeat(body.value);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      // The verified user id rides along so the DO can pin and enforce device
      // ownership (a co-member must not be able to spoof this device).
      const result = await team.stub.heartbeat(team.teamId, team.user.id, parsed.beat);
      if ("error" in result) return json({ error: result.error }, result.status);
      return json(result);
    }

    if (url.pathname === "/v1/presence/snapshot") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      const team = await resolveTeamOr403(request, env);
      if (!team.ok) return team.response;
      return new Response(await team.stub.snapshot(team.teamId), {
        headers: { "content-type": "application/json" },
      });
    }

    if (url.pathname === "/v1/presence/subscribe") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      const team = await resolveTeamOr403(request, env);
      if (!team.ok) return team.response;
      // Forward to the DO with the verified team id and a stream deadline
      // (token expiry capped at MAX_SUBSCRIBE_AGE_MS) so a revoked token or
      // removed member cannot keep an old stream alive indefinitely. Both
      // headers are set from verified values only, never passed through.
      const token = bearerToken(request);
      const expiresAt = cacheDeadline(
        Date.now(),
        token ? tokenExpiryMs(token) : null,
        MAX_SUBSCRIBE_AGE_MS,
      );
      const headers = new Headers(request.headers);
      headers.set("x-presence-team-id", team.teamId);
      headers.set("x-presence-expires-at", String(Math.floor(expiresAt)));
      return team.stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
