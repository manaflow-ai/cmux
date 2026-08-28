// cmux device presence service — worker entry.
//
// Routes (all JSON unless noted):
//   GET  /healthz                         liveness, no auth
//   POST /v1/presence/heartbeat           announce an app instance (15s cadence)
//   GET  /v1/presence/snapshot            one-shot presence map
//   GET  /v1/presence/subscribe           WebSocket upgrade or SSE stream:
//                                         snapshot first, then online/offline/seen
//   GET  /v1/connectivity/subscribe       quiet account route-revision stream
//   POST /v1/connectivity/invalidate      publish one account route revision
//   POST /v1/replies                      park one phone inline-notification reply
//   GET  /v1/replies?macDeviceId=…        pending replies for one Mac
//   POST /v1/replies/ack                  remove processed replies
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
import { MacRelay } from "./relayDo";
import { RELAY_MAX_SUBSCRIBE_AGE_MS, relayObjectName, validOpaqueId } from "./relayProtocol";
import {
  isConnectivityPublisherAuthorized,
  parseConnectivityInvalidation,
  parseHeartbeat,
  readBoundedJson,
} from "./validate";
import { MAX_PAIRED_MAC_BACKUP_BYTES, normalizeClientScope, parsePairedMacBackup } from "./syncPairedMacs";
import {
  MAX_PHONE_REPLY_BODY_BYTES,
  MAX_PHONE_REPLY_TARGET_ID_CHARS,
  parsePhoneReply,
  parsePhoneReplyAck,
} from "./replies";

export { TeamPresence };
export { MacRelay };

export interface Env extends AuthEnv {
  TEAM_PRESENCE: DurableObjectNamespace<TeamPresence>;
  MAC_RELAY: DurableObjectNamespace<MacRelay>;
  CONNECTIVITY_INVALIDATION_SECRET?: string;
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

/** The account-scoped connectivity DO: one instance per Stack user, owning the
 * account's live subscriber sockets AND its phone reply inbox, so a nudge and
 * the sockets it targets can never disagree about which object owns them. */
function connectivityStub(env: Env, userId: string): DurableObjectStub<TeamPresence> {
  return env.TEAM_PRESENCE.get(env.TEAM_PRESENCE.idFromName(`connectivity:user:${userId}`));
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

    // dot/1 data-plane relay: the Mac parks a standing "host" leg on its own
    // relay DO; phones connect legs to the same object. Auth happens HERE, at
    // the edge, and the DO id is derived from the VERIFIED user id, so an
    // unauthenticated caller can never materialize (or even address) a relay.
    if (url.pathname === "/v1/relay/host" || url.pathname === "/v1/relay/connect") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "websocket_required" }, 426);
      }
      const user = await verifyRequest(request, env);
      if (!user) return unauthorized();
      const mac = url.searchParams.get("mac")?.trim() ?? "";
      const device = url.searchParams.get("device")?.trim() ?? "";
      if (!validOpaqueId(mac) || !validOpaqueId(device)) {
        return json({ error: "invalid_request" }, 400);
      }
      const role = url.pathname.endsWith("/host") ? "host" : "phone";
      // The host leg's own device IS the Mac the relay is named for; a host
      // claiming someone else's slot within the account is refused.
      if (role === "host" && device !== mac) {
        return json({ error: "host_device_mismatch" }, 403);
      }
      const token = bearerToken(request);
      const expiresAt = cacheDeadline(
        Date.now(),
        token ? tokenExpiryMs(token) : null,
        RELAY_MAX_SUBSCRIBE_AGE_MS,
      );
      const headers = new Headers(request.headers);
      headers.set("x-relay-role", role);
      headers.set("x-relay-user-id", user.id);
      headers.set("x-relay-device", device);
      headers.set("x-relay-expires-at", String(Math.floor(expiresAt)));
      const stub = env.MAC_RELAY.get(
        env.MAC_RELAY.idFromName(relayObjectName(user.id, mac)),
      );
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    if (url.pathname === "/v1/connectivity/subscribe") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      const user = await verifyRequest(request, env);
      if (!user) return unauthorized();
      const token = bearerToken(request);
      const expiresAt = cacheDeadline(
        Date.now(),
        token ? tokenExpiryMs(token) : null,
        MAX_SUBSCRIBE_AGE_MS,
      );
      const headers = new Headers(request.headers);
      headers.set("x-connectivity-account-id", user.id);
      headers.set("x-presence-expires-at", String(Math.floor(expiresAt)));
      const stub = connectivityStub(env, user.id);
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    if (url.pathname === "/v1/connectivity/invalidate") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (!await isConnectivityPublisherAuthorized(
        request,
        env.CONNECTIVITY_INVALIDATION_SECRET,
      )) return unauthorized();
      const user = await verifyRequest(request, env);
      if (!user) return unauthorized();
      const body = await readBoundedJson(request, 1_024);
      if (!body.ok) return json({ error: "invalid_request" }, body.status);
      const parsed = parseConnectivityInvalidation(body.value);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const stub = connectivityStub(env, user.id);
      return json(await stub.invalidateConnectivity(
        user.id,
        parsed.invalidation.revision,
      ));
    }

    // Phone reply inbox: the phone parks an inline notification reply with one
    // authenticated POST; the Mac fetches and acks over the same account scope.
    // All three routes use the account's connectivity DO instance — the one
    // already holding the account's live WebSockets — so the enqueue nudge and
    // the sockets can never disagree about which object owns them.
    if (url.pathname === "/v1/replies") {
      const user = await verifyRequest(request, env);
      if (!user) return unauthorized();
      const stub = connectivityStub(env, user.id);
      if (request.method === "POST") {
        const body = await readBoundedJson(request, MAX_PHONE_REPLY_BODY_BYTES);
        if (!body.ok) return json({ error: "invalid_request" }, body.status);
        const parsed = parsePhoneReply(body.value);
        if (!parsed.ok) return json({ error: parsed.error }, 400);
        const result = await stub.enqueuePhoneReply(user.id, parsed.reply);
        if (!result.ok) return json({ error: result.error }, 429);
        return json(result);
      }
      if (request.method === "GET") {
        const macDeviceId = url.searchParams.get("macDeviceId")?.trim() ?? "";
        if (!macDeviceId || macDeviceId.length > MAX_PHONE_REPLY_TARGET_ID_CHARS) {
          return json({ error: "invalid_mac_device_id" }, 400);
        }
        return json({ replies: await stub.listPhoneReplies(macDeviceId) });
      }
      return json({ error: "method_not_allowed" }, 405);
    }

    if (url.pathname === "/v1/replies/ack") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const user = await verifyRequest(request, env);
      if (!user) return unauthorized();
      const body = await readBoundedJson(request, MAX_PHONE_REPLY_BODY_BYTES);
      if (!body.ok) return json({ error: "invalid_request" }, body.status);
      const parsed = parsePhoneReplyAck(body.value);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const stub = connectivityStub(env, user.id);
      return json(await stub.ackPhoneReplies(parsed.replyIds));
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

    if (url.pathname === "/v1/sync/paired-macs") {
      // The per-user saved-host backup. Both directions are scoped to the
      // verified user (passed to the DO, never client input):
      //   POST  back up the caller's saved-host list (upsert/delete ops)
      //   GET   read it back (the sign-in restore path on a fresh install)
      const team = await resolveTeamOr403(request, env);
      if (!team.ok) return team.response;
      const rawClientScope = request.headers.get("x-cmux-client-scope");
      const trimmedClientScope = rawClientScope?.trim() ?? "";
      if (trimmedClientScope && normalizeClientScope(trimmedClientScope) === null) {
        return json({ error: "invalid_client_scope" }, 400);
      }
      const clientScope = trimmedClientScope || null;
      // Both responses echo the VERIFIED resolved team (never client input
      // passed through) so the phone can persist which per-team DO its
      // records were actually stored in: a nil-team request is resolved
      // server-side, and the client needs that resolution to route a later
      // delete tombstone to the same backup instead of re-resolving nil at
      // delete time (which can drift to a different team's DO).
      if (request.method === "GET") {
        return json(await team.stub.listPairedMacs(team.teamId, team.user.id, clientScope));
      }
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      // A full backup reconcile can far exceed the 16 KiB heartbeat cap, so size
      // the bound to the declared paired-Mac limits instead of dropping it.
      const body = await readBoundedJson(request, MAX_PAIRED_MAC_BACKUP_BYTES);
      if (!body.ok) return json({ error: "invalid_request" }, body.status);
      const parsed = parsePairedMacBackup(body.value);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await team.stub.backupPairedMacs(
        team.teamId,
        team.user.id,
        parsed.ops,
        clientScope,
        parsed.expectedRevision,
      );
      if (!result.ok) return json({ error: result.error }, result.status);
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
      // Forward the verified user id so the DO can scope the per-user
      // `pairedMacs` backup collection to its owner. Set from the verified value
      // only, never passed through from the client.
      headers.set("x-presence-user-id", team.user.id);
      return team.stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
