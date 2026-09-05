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
//   GET  /v1/control/socket               account control-plane WebSocket:
//                                         revisioned directory/hint/pass facts
//   POST /v1/control/devices/revoke       flip one device's revoked flag
//                                         ({endpointId, revoked}); the DO
//                                         broadcasts, closes that device's
//                                         sockets, and refuses its mints
//   POST /v1/replies                      park one phone inline-notification reply
//   GET  /v1/replies?macDeviceId=…        pending replies for one Mac
//   POST /v1/replies/ack                  remove processed replies
//
// Legacy presence and backup routes use `Authorization: Bearer <Stack access
// token>` plus optional team scoping. Current Iroh control routes bootstrap
// once with that bearer, then use a signed session ticket at the edge and the
// account Durable Object for every ordinary request. The DO never sees
// unauthenticated input.

import {
  bearerToken,
  cacheDeadline,
  requestedTeamIdFromRequest,
  resolveTeamId,
  tokenExpiryMs,
  verifyIdentityRequest,
  verifyRequest,
  type AuthedUser,
  type AuthEnv,
} from "./auth";
import { MAX_SUBSCRIBE_AGE_MS, TeamPresence } from "./do";
import { AccountControlPlane, type ControlPlaneEnv } from "./controlPlaneDo";
import { parseRevocationRequest } from "./controlPlane";
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
import { captureSentryException } from "./sentry";
import {
  IROH_SESSION_TICKET_HEADER,
  parseIrohSessionClientContext,
  sessionClientContextFromClaims,
  sessionClientNamespaceMatches,
  sessionTicketFromRequest,
  verifyIrohSessionTicket,
  type IrohSessionVerification,
} from "./irohSession";
export { TeamPresence, AccountControlPlane };

export interface Env extends AuthEnv, ControlPlaneEnv {
  TEAM_PRESENCE: DurableObjectNamespace<TeamPresence>;
  ACCOUNT_CONTROL_PLANE: DurableObjectNamespace<AccountControlPlane>;
  CONNECTIVITY_INVALIDATION_SECRET?: string;
  IROH_SESSION_SIGNING_KEY?: string;
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

function sessionVerificationError(
  error: Extract<IrohSessionVerification, { readonly ok: false }>["error"],
): Response {
  // Configuration state is an operator concern, not an authentication detail
  // for callers. Keep the retryable 503 distinct while using the normal
  // session error vocabulary for malformed or expired tickets.
  return error === "not_configured"
    ? json({ error: "session_unavailable" }, 503)
    : json({ error: `session_${error}` }, 401);
}

const IROH_CONTROL_PATHS = new Map<string, ReadonlySet<string>>([
  ["/api/devices/iroh", new Set(["GET", "DELETE"])],
  ["/api/devices/iroh/challenge", new Set(["POST"])],
  ["/api/devices/iroh/register", new Set(["POST"])],
  ["/api/devices/iroh/pair-grants", new Set(["POST"])],
  ["/api/devices/iroh/endpoint-attestations", new Set(["POST"])],
  ["/api/devices/iroh/relay-token", new Set(["POST"])],
  ["/api/relay/token", new Set(["POST"])],
  ["/api/relay/preferences", new Set(["GET", "PUT"])],
  ["/api/connectivity/v2/sync", new Set(["POST"])],
  ["/api/connectivity/v3/sync", new Set(["POST"])],
]);

function accountControlStub(env: Env, accountId: string): DurableObjectStub<AccountControlPlane> {
  return env.ACCOUNT_CONTROL_PLANE.get(
    env.ACCOUNT_CONTROL_PLANE.idFromName(`control:user:${accountId}`),
  );
}

/** Upgrade a pre-session client at the edge. This path is only for old app
 * builds that still send Stack credentials on every Iroh request. Stack is
 * still verified (through the short identity cache), then the account DO
 * mints the same local ticket used by current clients. The credentials are
 * removed before the request enters the DO, so even the compatibility lane
 * has one authorization authority and direct mode does not need Stack tokens.
 */
async function upgradeLegacyIrohRequest(
  env: Env,
  accountId: string,
  requestId: string,
): Promise<string | Response> {
  const headers = new Headers();
  headers.set("x-control-account-id", accountId);
  headers.set("content-type", "application/json");
  headers.set("x-cmux-request-id", requestId);
  const opened = await accountControlStub(env, accountId).fetch(new Request(
    "https://cmux.internal/_internal/iroh/session/open",
    { method: "POST", headers, body: "{}" },
  ));
  if (!opened.ok) return opened;
  let payload: unknown;
  try {
    payload = await opened.json();
  } catch {
    return json({ error: "session_invalid_response" }, 503);
  }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)
    || typeof (payload as { ticket?: unknown }).ticket !== "string") {
    return json({ error: "session_invalid_response" }, 503);
  }
  return (payload as { ticket: string }).ticket;
}

function requestID(request: Request): string {
  const supplied = request.headers.get("x-cmux-request-id")?.trim();
  return supplied && /^[A-Za-z0-9._:-]{1,128}$/.test(supplied)
    ? supplied
    : crypto.randomUUID();
}

function validSessionOpenBody(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  // Keep the public bootstrap parser identical to the DO's internal renewal
  // parser. A partial client context is ambiguous and must not mint a ticket
  // whose namespace/account binding is weaker than the advertised contract.
  return parseIrohSessionClientContext(value) !== null;
}

async function readSessionOpenBody(request: Request): Promise<Record<string, unknown> | null> {
  const length = request.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > 8 * 1_024)) return null;
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > 8 * 1_024) return null;
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    return validSessionOpenBody(value) ? value : null;
  } catch {
    return null;
  }
}

const MAX_IROH_CONTROL_BODY_BYTES = 64 * 1_024;

async function readIrohControlBody(request: Request): Promise<ArrayBuffer | null> {
  const length = request.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > MAX_IROH_CONTROL_BODY_BYTES)) {
    return null;
  }
  const bytes = await request.arrayBuffer();
  return bytes.byteLength <= MAX_IROH_CONTROL_BODY_BYTES ? bytes : null;
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

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-presence" });
    }

    // Iroh session bootstrap is the one control-plane request that carries a
    // Stack bearer. Identity-only verification deliberately does not resolve
    // team membership: Iroh state is scoped to the personal Stack user.
    if (url.pathname === "/v1/iroh/session") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const user = await verifyIdentityRequest(request, env);
      if (!user) return unauthorized();
      const body = await readSessionOpenBody(request);
      if (body === null) return json({ error: "invalid_request" }, 400);
      const headers = new Headers();
      headers.set("x-control-account-id", user.id);
      headers.set("content-type", "application/json");
      headers.set("x-cmux-request-id", requestID(request));
      return accountControlStub(env, user.id).fetch(new Request(
        "https://cmux.internal/_internal/iroh/session/open",
        { method: "POST", headers, body: JSON.stringify(body) },
      ));
    }

    if (url.pathname === "/v1/iroh/session/renew") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const ticket = sessionTicketFromRequest(request);
      if (!ticket) return json({ error: "session_required" }, 401);
      // Renewal is ticket-only. The existing signed ticket and the account DO
      // epoch are the proof of the already-authenticated session; requiring a
      // second Stack request here would reintroduce the reconnect storm this
      // endpoint is meant to eliminate. A ticket that has expired must use the
      // bootstrap route, which performs the one Stack identity check.
      const ticketVerification = await verifyIrohSessionTicket(
        env.IROH_SESSION_SIGNING_KEY,
        ticket,
        Date.now(),
      );
      if (!ticketVerification.ok) return sessionVerificationError(ticketVerification.error);
      const headers = new Headers();
      headers.set("x-control-account-id", ticketVerification.claims.accountId);
      headers.set(IROH_SESSION_TICKET_HEADER, ticket);
      if (ticketVerification.claims.clientNamespace) {
        headers.set("x-cmux-app-namespace", ticketVerification.claims.clientNamespace);
      }
      headers.set("x-cmux-request-id", requestID(request));
      return accountControlStub(env, ticketVerification.claims.accountId).fetch(new Request(
        "https://cmux.internal/_internal/iroh/session/renew",
        { method: "POST", headers },
      ));
    }

    if (url.pathname === "/v1/iroh/session/revoke-all") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const user = await verifyIdentityRequest(request, env);
      if (!user) return unauthorized();
      const headers = new Headers();
      headers.set("x-control-account-id", user.id);
      headers.set("x-cmux-request-id", requestID(request));
      return accountControlStub(env, user.id).fetch(new Request(
        "https://cmux.internal/_internal/iroh/session/revoke-all",
        { method: "POST", headers },
      ));
    }

    // All Iroh HTTP control operations share the same account DO. The edge
    // verifies only the ticket signature and derives the object id from its
    // claims, so ordinary challenge/discovery/mint traffic never calls Stack.
    const irohMethods = IROH_CONTROL_PATHS.get(url.pathname);
    if (irohMethods) {
      if (!irohMethods.has(request.method)) return json({ error: "method_not_allowed" }, 405);
      let ticket = sessionTicketFromRequest(request);
      let accountId: string;
      if (ticket) {
        const verification = await verifyIrohSessionTicket(
          env.IROH_SESSION_SIGNING_KEY,
          ticket,
          Date.now(),
        );
        if (!verification.ok) {
          return sessionVerificationError(verification.error);
        }
        accountId = verification.claims.accountId;
      } else {
        // Pre-session app builds are upgraded once at the edge. A present but
        // invalid ticket never falls through to this branch, so an attacker
        // cannot turn a malformed bearer into a different auth mechanism.
        const user = await verifyIdentityRequest(request, env);
        if (!user) return unauthorized();
        accountId = user.id;
        const upgraded = await upgradeLegacyIrohRequest(env, accountId, requestID(request));
        if (upgraded instanceof Response) return upgraded;
        ticket = upgraded;
      }
      if (!ticket) return json({ error: "session_required" }, 401);
      const headers = new Headers(request.headers);
      // These are deliberately rebuilt rather than forwarded. A caller cannot
      // choose an account id or smuggle a Stack credential into the DO.
      headers.delete("authorization");
      headers.delete("x-stack-refresh-token");
      headers.delete("cookie");
      headers.set("x-control-account-id", accountId);
      headers.set(IROH_SESSION_TICKET_HEADER, ticket);
      headers.set("x-cmux-request-id", requestID(request));
      const init: RequestInit = { method: request.method, headers };
      if (request.method !== "GET" && request.method !== "HEAD") {
        const body = await readIrohControlBody(request);
        if (body === null) return json({ error: "request_too_large" }, 413);
        init.body = body;
      }
      return accountControlStub(env, accountId).fetch(
        new Request(request.url, init),
      );
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

    if (url.pathname === "/v1/control/socket") {
      // Account control plane: one WebSocket carrying revisioned facts
      // (directory, hint updates, relay passes). Auth is checked on the
      // WebSocket upgrade here, and the DO is derived from the VERIFIED user
      // id. The socket itself is long-lived; hibernation controls DO memory,
      // not the WebSocket lifetime. The DO additionally
      // keeps the connection's own bearer (already on the forwarded headers)
      // for its upstream broker proxy calls — never its own credentials.
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "websocket_required" }, 400);
      }
      const namespace = request.headers.get("x-cmux-app-namespace")?.trim();
      if (namespace && !/^[A-Za-z0-9._:-]{1,255}$/.test(namespace)) {
        return json({ error: "invalid_client_namespace" }, 400);
      }
      const headers = new Headers(request.headers);
      const ticket = sessionTicketFromRequest(request);
      let accountId: string;
      if (ticket) {
        const verified = await verifyIrohSessionTicket(
          env.IROH_SESSION_SIGNING_KEY,
          ticket,
          Date.now(),
        );
        if (!verified.ok) return sessionVerificationError(verified.error);
        accountId = verified.claims.accountId;
        const context = sessionClientContextFromClaims(verified.claims);
        if (!sessionClientNamespaceMatches(context, namespace)) {
          return json({ error: "client_namespace_mismatch" }, 403);
        }
        headers.delete("authorization");
        headers.delete("x-stack-refresh-token");
        headers.delete("cookie");
        headers.set(IROH_SESSION_TICKET_HEADER, ticket);
      } else {
        // Compatibility path for pre-session clients. New clients never take
        // this branch after their bootstrap succeeds.
        const user = await verifyRequest(request, env);
        if (!user) return unauthorized();
        accountId = user.id;
      }
      headers.set("x-control-account-id", accountId);
      const stub = accountControlStub(env, accountId);
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    if (url.pathname === "/v1/control/devices/revoke") {
      // Account-owner device revocation. Same Stack bearer verification as the
      // control-plane socket route; the target DO is derived from the VERIFIED
      // user id, the forwarded headers are rebuilt from scratch, and only the
      // strict-parsed body travels — a client-supplied account id has no
      // channel here.
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const user = await verifyRequest(request, env);
      if (!user) return unauthorized();
      const body = await readBoundedJson(request, 1_024);
      if (!body.ok) return json({ error: "invalid_request" }, body.status);
      const parsed = parseRevocationRequest(body.value);
      if (parsed === null) return json({ error: "invalid_request" }, 400);
      const headers = new Headers();
      headers.set("x-control-account-id", user.id);
      headers.set("content-type", "application/json");
      const stub = env.ACCOUNT_CONTROL_PLANE.get(
        env.ACCOUNT_CONTROL_PLANE.idFromName(`control:user:${user.id}`),
      );
      return stub.fetch(new Request(request.url, {
        method: "POST",
        headers,
        body: JSON.stringify(parsed),
      }));
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

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await worker.fetch(request, env);
    } catch (error) {
      await captureSentryException(env, "cloudflare-worker", error, {
        durable_object: "worker-router",
        operation: "fetch",
        path: new URL(request.url).pathname,
        method: request.method,
      });
      return json({ error: "internal_error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
