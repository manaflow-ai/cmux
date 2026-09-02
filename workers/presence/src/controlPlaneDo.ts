// AccountControlPlane Durable Object — one instance per verified Stack user
// (the worker derives the id from the VERIFIED user id, never client input).
//
// Thin adapter: all protocol logic lives in controlPlane.ts (bun-testable);
// this file binds it to workerd — WebSocket hibernation, DO storage, the DO
// alarm, and upstream fetch against the configured Vercel base URL.
//
// Authorization happens in the worker before anything reaches this object
// (same trust model as TeamPresence): the worker verifies the Stack bearer
// token and resolves the account. Control-plane sockets are intentionally
// long-lived; the DO uses ONLY the connecting client's own bearer token for
// upstream calls, stored per-socket and deleted on close.

import { DurableObject } from "cloudflare:workers";
import { bearerToken } from "./auth";
import {
  CONTROL_REFRESH_INTERVAL_MS,
  ControlPlaneCore,
  MAX_CONTROL_SUBSCRIBERS_PER_ACCOUNT,
  parseRevocationRequest,
  type CtlAttachment,
  type CtlSocket,
  type CtlStorage,
} from "./controlPlane";

export interface ControlPlaneEnv {
  /** Vercel web API origin the DO proxies (dev/prod), e.g. https://cmux.com.
   * Same optional-with-production-default pattern as STACK_API_URL. */
  CMUX_WEB_BASE_URL?: string;
}

const PRODUCTION_WEB_BASE_URL = "https://cmux.com";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Wrap a hibernatable WebSocket as the core's transport-neutral socket. The
 * attachment rides serializeAttachment so it survives DO hibernation. */
function wrapSocket(ws: WebSocket): CtlSocket {
  return {
    send(data: string): void {
      ws.send(data);
    },
    close(code?: number, reason?: string): void {
      ws.close(code, reason);
    },
    getAttachment(): CtlAttachment | null {
      try {
        const attachment = ws.deserializeAttachment() as CtlAttachment | null;
        return attachment && typeof attachment.sessionId === "string"
          && (attachment.expiresAt === undefined || typeof attachment.expiresAt === "number")
          ? attachment
          : null;
      } catch {
        return null;
      }
    },
    setAttachment(attachment: CtlAttachment): void {
      try {
        ws.serializeAttachment(attachment);
      } catch {
        // attachment write failed; the socket is likely gone
      }
    },
  };
}

export class AccountControlPlane extends DurableObject<ControlPlaneEnv> {
  private readonly core = new ControlPlaneCore({
    // DurableObjectStorage's get/put/delete structurally cover CtlStorage;
    // single widening cast, same pattern as TeamPresence.syncStorage().
    storage: this.ctx.storage as unknown as CtlStorage,
    now: () => Date.now(),
    upstream: async (path, init) => {
      const base = (this.env.CMUX_WEB_BASE_URL ?? PRODUCTION_WEB_BASE_URL).replace(/\/+$/, "");
      let response: Response;
      try {
        response = await fetch(`${base}${path}`, {
          method: init.method,
          headers: init.headers,
          ...(init.body !== undefined ? { body: init.body } : {}),
        });
      } catch (error) {
        // Preserve connection-level failures for the core's one immediate
        // retry, while leaving a safe, token-free breadcrumb in the DO tail.
        console.error(
          `control-plane upstream ${init.method} ${path} network failure`,
          String(error).slice(0, 300),
        );
        throw error;
      }
      // A connection-level failure throws out of fetch (the core's retry-once
      // trigger); any HTTP response resolves and is never retried.
      const json = await response.json().catch(() => null);
      if (response.status >= 400) {
        // Upstream refusals must be attributable from the worker tail alone;
        // clients only ever see the mapped retryable/non-retryable error code.
        console.error(
          `control-plane upstream ${init.method} ${path} -> ${response.status}`,
          JSON.stringify(json)?.slice(0, 300) ?? "<no body>",
        );
      }
      return { status: response.status, json };
    },
    scheduleAlarmAt: (atMs) => this.ensureAlarmAt(atMs),
    sockets: () => this.ctx.getWebSockets().map(wrapSocket),
  });

  override async fetch(request: Request): Promise<Response> {
    // Device revocation, forwarded by the worker with rebuilt headers after
    // Stack bearer verification. This DO instance IS the verified account
    // scope; the strict-parsed body carries only {endpointId, revoked}.
    if (request.method === "POST"
      && new URL(request.url).pathname === "/v1/control/devices/revoke") {
      if (!request.headers.get("x-control-account-id")?.trim()) {
        return json({ error: "account_required" }, 403);
      }
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid_request" }, 400);
      }
      const parsed = parseRevocationRequest(body);
      if (parsed === null) return json({ error: "invalid_request" }, 400);
      const result = await this.core.handleRevocation(parsed);
      return json({ ok: true, ...result }, 200);
    }
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "websocket_required" }, 400);
    }
    // Verified by the worker; never client input.
    const accountId = request.headers.get("x-control-account-id")?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    // The DO keeps the connection's own bearer for its upstream proxy calls.
    const bearer = bearerToken(request);
    if (!bearer) return json({ error: "unauthorized" }, 401);
    // The web API's native auth requires the refresh token BESIDE the bearer
    // (parseNativeStackTokens); without it every upstream proxy call 401s.
    const refresh = request.headers.get("x-stack-refresh-token")?.trim() || undefined;
    const namespace = request.headers.get("x-cmux-app-namespace")?.trim() || undefined;

    const connected = this.ctx.getWebSockets().filter((ws) => {
      const attachment = wrapSocket(ws).getAttachment();
      return attachment !== null;
    }).length;
    if (connected >= MAX_CONTROL_SUBSCRIBERS_PER_ACCOUNT) {
      return json({ error: "too_many_subscribers" }, 429);
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    // Hibernation API: the DO can be evicted while sockets stay connected.
    this.ctx.acceptWebSocket(server);
    await this.core.handleConnect(wrapSocket(server), {
      sessionId: crypto.randomUUID(),
      bearer,
      ...(refresh ? { refresh } : {}),
      ...(namespace ? { namespace } : {}),
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    await this.core.handleMessage(wrapSocket(ws), message);
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    await this.core.handleClose(wrapSocket(ws));
    try {
      ws.close();
    } catch {
      // already closed
    }
  }

  override async alarm(): Promise<void> {
    await this.core.handleAlarm();
  }

  /** Pull the alarm earlier if `due` precedes the currently scheduled one
   * (same ensure-at semantics as TeamPresence). The alarm handler reschedules
   * the steady CONTROL_REFRESH_INTERVAL_MS cadence itself while sockets are
   * connected, so this only ever needs the cheap min(). */
  private async ensureAlarmAt(due: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > due) {
      await this.ctx.storage.setAlarm(due);
    }
  }
}

/** Re-exported so wrangler migrations and the worker Env can reference one
 * canonical cadence constant from the adapter module. */
export { CONTROL_REFRESH_INTERVAL_MS };
