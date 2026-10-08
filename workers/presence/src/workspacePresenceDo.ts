import { DurableObject } from "cloudflare:workers";
import { resolveSubscribeDeadline } from "./core";
import { MAX_VIEW_SOCKETS, VIEW_AUTH_MS, VIEW_RENEW_MS, parseViewing, parseWorkspaceScope, renewViewer, workspaceViewers, type ViewerLease, type ViewerParticipant } from "./workspacePresence";

/** Owns one authorized workspace's live viewing leases in hibernating sockets. */
export class WorkspacePresence extends DurableObject {
  /** Authenticates a viewer, opens its lease, and publishes the initial roster. */
  async fetch(request: Request): Promise<Response> {
    const scope = parseWorkspaceScope(JSON.parse(request.headers.get("x-workspace-scope") ?? "null"));
    const identity = JSON.parse(request.headers.get("x-workspace-viewer") ?? "null");
    const now = Date.now();
    const expiresAt = resolveSubscribeDeadline(request.headers.get("x-workspace-expires"), now, VIEW_AUTH_MS);
    if (!scope || !identity?.id || expiresAt === null) return new Response(null, { status: 401 });
    if (this.ctx.getWebSockets().length >= MAX_VIEW_SOCKETS) {
      return new Response(null, { status: 429, headers: { "Retry-After": "15" } });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment({ scope, identity, expiresAt, viewingUntil: 0 } satisfies ViewerLease);
    // Passive rows are part of the roster too. Broadcast the new lease so
    // existing viewers see its dimmed head immediately, before the client’s
    // first `active: false` acknowledgement arrives.
    this.broadcast();
    await this.schedule();
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** Validates a focus update and broadcasts only when the roster changes. */
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const active = parseViewing(message);
    const lease = this.lease(ws);
    const now = Date.now();
    if (active === null || !lease || lease.expiresAt <= now) {
      ws.close(1008, "Invalid or expired viewing session");
      return;
    }
    const before = workspaceViewers(this.leases(), now);
    ws.serializeAttachment(renewViewer(lease, active, now));
    const after = workspaceViewers(this.leases(), now);
    if (JSON.stringify(before) !== JSON.stringify(after)) this.broadcast();
    else this.snapshot(ws); // Lease acknowledgement also proves stream liveness.
    await this.schedule();
  }

  /** Removes a closed viewer and publishes the remaining roster. */
  async webSocketClose(ws: WebSocket): Promise<void> {
    ws.serializeAttachment(null);
    this.broadcast();
    await this.schedule();
  }

  /** Removes a failed viewer before closing its socket. */
  async webSocketError(ws: WebSocket): Promise<void> {
    ws.serializeAttachment(null);
    ws.close(1011, "Connection ended");
    this.broadcast();
    await this.schedule();
  }

  /** Expires auth and focus leases, then publishes the resulting roster. */
  async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const lease = this.lease(ws);
      if (!lease) continue;
      if (lease.expiresAt <= now) {
        ws.serializeAttachment(null);
        ws.close(1008, "Reauthenticate");
      } else if (lease.viewingUntil > 0 && lease.viewingUntil <= now) {
        ws.serializeAttachment({ ...lease, viewingUntil: 0 });
      }
    }
    this.broadcast();
    await this.schedule();
  }

  /** Reads one socket's authenticated lease attachment. */
  private lease(ws: WebSocket): ViewerLease | null {
    try { return ws.deserializeAttachment() as ViewerLease | null; } catch { return null; }
  }
  /** Returns the valid lease attachments currently held by the room. */
  private leases(): ViewerLease[] {
    return this.ctx.getWebSockets().flatMap((ws) => { const lease = this.lease(ws); return lease ? [lease] : []; });
  }
  /** Sends one current snapshot, using a supplied roster when broadcast has already built it. */
  private snapshot(ws: WebSocket, participants?: readonly ViewerParticipant[]): void {
    const lease = this.lease(ws);
    if (!lease || lease.expiresAt <= Date.now()) return;
    try {
      ws.send(JSON.stringify({ type: "workspace.presence", version: 1, scope: lease.scope,
        renewAfterMs: VIEW_RENEW_MS,
        participants: participants ?? workspaceViewers(this.leases(), Date.now()) }));
    } catch { ws.serializeAttachment(null); }
  }
  /** Builds one roster and shares it across every eligible socket in the room. */
  private broadcast(): void {
    const participants = workspaceViewers(this.leases(), Date.now());
    for (const ws of this.ctx.getWebSockets()) this.snapshot(ws, participants);
  }
  private async schedule(): Promise<void> {
    const now = Date.now();
    const deadlines = this.leases().flatMap((s) => [s.expiresAt, s.viewingUntil]).filter((t) => t > now);
    if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines));
    else await this.ctx.storage.deleteAlarm();
  }
}
