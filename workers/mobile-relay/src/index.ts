// cmux mobile relay — worker entry.
//
// Routes:
//   GET /healthz       liveness, no auth
//   GET /v1/connect    WebSocket upgrade. Auth: `x-cmux-relay-ticket` header
//                      carrying a web-app-minted HMAC ticket. The worker
//                      verifies the ticket, derives the HostRelay object id
//                      from the VERIFIED claims (`v1:<userId>:<hostDeviceId>`),
//                      stamps verified-identity headers, and forwards. The
//                      object never sees an unverified connect.
//
// Stack bearer tokens never reach this worker; the web app owns Stack auth
// and device-registry ownership checks at ticket mint time
// (web/app/api/mobile-relay/ticket). See src/protocol.ts for the wire
// contract and workers/mobile-relay/README.md for operations.

import {
  HostRelay,
  RELAY_DEVICE_HEADER,
  RELAY_HOST_DEVICE_HEADER,
  RELAY_ROLE_HEADER,
  RELAY_USER_HEADER,
  type RelayEnv,
} from "./do";
import { verifyTicket } from "./ticket";

export { HostRelay };

export interface Env extends RelayEnv {
  HOST_RELAY: DurableObjectNamespace<HostRelay>;
}

export const TICKET_HEADER = "x-cmux-relay-ticket";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function relayObjectName(userId: string, hostDeviceId: string): string {
  return `v1:${userId}:${hostDeviceId}`;
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
      const secret = env.MOBILE_RELAY_TICKET_SECRET;
      if (!secret) return json({ error: "relay_not_configured" }, 503);
      const ticket = request.headers.get(TICKET_HEADER);
      if (!ticket) return json({ error: "missing_ticket" }, 401);
      const verified = await verifyTicket(secret, ticket, Date.now());
      if (!verified.ok) return json({ error: verified.error }, 401);
      const { claims } = verified;

      const id = env.HOST_RELAY.idFromName(relayObjectName(claims.userId, claims.hostDeviceId));
      const stub = env.HOST_RELAY.get(id);
      // Forward with verified-identity headers only; the ticket itself is not
      // forwarded (refresh tickets travel in-band and are re-verified by the
      // object).
      const headers = new Headers(request.headers);
      headers.delete(TICKET_HEADER);
      headers.set(RELAY_ROLE_HEADER, claims.role);
      headers.set(RELAY_USER_HEADER, claims.userId);
      headers.set(RELAY_HOST_DEVICE_HEADER, claims.hostDeviceId);
      headers.set(RELAY_DEVICE_HEADER, claims.deviceId);
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
