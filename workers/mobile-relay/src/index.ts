// cmux mobile relay — worker entry.
//
// Routes:
//   GET /healthz       liveness, no auth
//   GET /v1/connect    WebSocket upgrade. Auth: the endpoint's own Stack
//                      access token in `x-cmux-stack-access` plus role and
//                      device headers. The worker verifies the token against
//                      the Stack API (short per-isolate verdict cache),
//                      derives the HostRelay object id from the VERIFIED user
//                      id (`v2:<userId>:<hostDeviceId>`), stamps
//                      verified-identity headers, and forwards. The object
//                      never sees an unverified connect, and a token can
//                      never reach another user's relay: isolation is by
//                      construction of the object name.
//
// There is no ticket and no web-app involvement. The web app's device
// registry is not consulted: a client that names an arbitrary hostDeviceId
// still lands on an object namespaced by its OWN verified user id, and the
// host additionally admits each session end to end (mobile.session.admit)
// before serving it. See src/protocol.ts for the wire contract and
// workers/mobile-relay/README.md for operations.

import {
  HostRelay,
  RELAY_DEVICE_HEADER,
  RELAY_HOST_DEVICE_HEADER,
  RELAY_ROLE_HEADER,
  RELAY_USER_HEADER,
  type RelayEnv,
} from "./do";
import {
  DEVICE_HEADER,
  HOST_DEVICE_HEADER,
  MAX_DEVICE_ID_CHARS,
  ROLE_HEADER,
  STACK_ACCESS_HEADER,
} from "./protocol";
import { verifyStackAccessToken } from "./stackAuth";

export { HostRelay };

export interface Env extends RelayEnv {
  HOST_RELAY: DurableObjectNamespace<HostRelay>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function relayObjectName(userId: string, hostDeviceId: string): string {
  return `v2:${userId}:${hostDeviceId}`;
}

function normalizedDeviceId(raw: string | null): string | null {
  const trimmed = raw?.trim().toLowerCase();
  if (!trimmed || trimmed.length > MAX_DEVICE_ID_CHARS) return null;
  return trimmed;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-mobile-relay" });
    }

    if (url.pathname === "/v1/connect") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected_websocket" }, 426);
      }
      const role = request.headers.get(ROLE_HEADER);
      if (role !== "host" && role !== "client") return json({ error: "invalid_role" }, 400);
      const hostDeviceId = normalizedDeviceId(request.headers.get(HOST_DEVICE_HEADER));
      const deviceId = normalizedDeviceId(request.headers.get(DEVICE_HEADER));
      if (!hostDeviceId || !deviceId) return json({ error: "invalid_device" }, 400);
      // A host proves it is connecting for itself; the object name pins it.
      if (role === "host" && deviceId !== hostDeviceId) {
        return json({ error: "host_device_mismatch" }, 400);
      }
      const accessToken = request.headers.get(STACK_ACCESS_HEADER);
      if (!accessToken) return json({ error: "missing_token" }, 401);
      const verified = await verifyStackAccessToken(env, accessToken, Date.now());
      if (!verified.ok) {
        return json(
          { error: verified.error },
          verified.error === "invalid_token" ? 401 : 503,
        );
      }

      const id = env.HOST_RELAY.idFromName(relayObjectName(verified.userId, hostDeviceId));
      const stub = env.HOST_RELAY.get(id);
      // Forward with verified-identity headers only; the access token is not
      // forwarded (in-band refresh tokens are re-verified by the object).
      const headers = new Headers(request.headers);
      headers.delete(STACK_ACCESS_HEADER);
      headers.set(RELAY_ROLE_HEADER, role);
      headers.set(RELAY_USER_HEADER, verified.userId);
      headers.set(RELAY_HOST_DEVICE_HEADER, hostDeviceId);
      headers.set(RELAY_DEVICE_HEADER, deviceId);
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
