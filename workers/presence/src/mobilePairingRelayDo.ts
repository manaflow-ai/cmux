// MobilePairingRelay Durable Object — one instance per Mac device id, relaying
// opaque binary frames between exactly one "host" (Mac) socket and one
// "client" (phone/Android) socket. All protocol logic lives in
// mobilePairingRelay.ts (bun-testable); this file binds it to workerd —
// WebSocket hibernation and per-socket role/account attachment.
//
// Authorization happens in the worker before anything reaches this object
// (same trust model as TeamPresence/AccountControlPlane): the worker verifies
// the Stack bearer token and forwards the verified account id. This DO adds
// one more check the worker cannot make on its own — that the two legs
// belong to the SAME verified account — since a single worker request only
// ever sees one leg at a time.

import { DurableObject } from "cloudflare:workers";
import {
  decideConnect,
  forwardMessage,
  type MprAttachment,
  type MprRole,
  type MprSocket,
} from "./mobilePairingRelay";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Wrap a hibernatable WebSocket as the core's transport-neutral socket. The
 * attachment rides serializeAttachment so it survives DO hibernation (same
 * technique as controlPlaneDo.ts's wrapSocket). */
function wrapSocket(ws: WebSocket): MprSocket {
  return {
    send(data: string | ArrayBuffer): void {
      ws.send(data);
    },
    close(code?: number, reason?: string): void {
      ws.close(code, reason);
    },
    getAttachment(): MprAttachment | null {
      try {
        const attachment = ws.deserializeAttachment() as MprAttachment | null;
        return attachment
          && typeof attachment.role === "string"
          && (attachment.role === "host" || attachment.role === "client")
          && typeof attachment.accountId === "string"
          && attachment.accountId.length > 0
          ? attachment
          : null;
      } catch {
        return null;
      }
    },
    setAttachment(attachment: MprAttachment): void {
      try {
        ws.serializeAttachment(attachment);
      } catch {
        // attachment write failed; the socket is likely gone
      }
    },
  };
}

function roleFromPath(pathname: string): MprRole | null {
  if (pathname.endsWith("/host")) return "host";
  if (pathname.endsWith("/client")) return "client";
  return null;
}

export class MobilePairingRelay extends DurableObject {
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "websocket_required" }, 400);
    }
    const role = roleFromPath(new URL(request.url).pathname);
    if (role === null) return json({ error: "invalid_role" }, 400);
    // Verified by the worker; never client input.
    const accountId = request.headers.get("x-mobile-relay-account-id")?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);

    const sockets = this.ctx.getWebSockets().map(wrapSocket);
    const decision = decideConnect(sockets, role, accountId);
    if (!decision.ok) return json({ error: "account_mismatch" }, 403);

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    // Hibernation API: the DO can be evicted while sockets stay connected.
    this.ctx.acceptWebSocket(server);
    for (const evicted of decision.toEvict) {
      try {
        evicted.close(1000, "replaced by a newer connection");
      } catch {
        // already closed
      }
    }
    wrapSocket(server).setAttachment({ role, accountId });
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    forwardMessage(this.ctx.getWebSockets().map(wrapSocket), wrapSocket(ws), message);
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    try {
      ws.close();
    } catch {
      // already closed
    }
  }
}
