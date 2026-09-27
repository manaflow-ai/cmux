import { DurableObject } from "cloudflare:workers";
import { resolveSubscribeDeadline } from "./core";
import { MAX_VIEW_SOCKETS, VIEW_AUTH_MS, VIEW_RENEW_MS, parseViewing, parseWorkspaceScope, renewViewer, workspaceViewers, type ViewerLease } from "./workspacePresence";

/** Owns one authorized workspace's live viewing leases in hibernating sockets. */
export class WorkspacePresence extends DurableObject {
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
    this.snapshot(pair[1]);
    await this.schedule();
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

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

  async webSocketClose(ws: WebSocket): Promise<void> {
    ws.serializeAttachment(null);
    this.broadcast();
    await this.schedule();
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    ws.serializeAttachment(null);
    ws.close(1011, "Connection ended");
    this.broadcast();
    await this.schedule();
  }

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

  private lease(ws: WebSocket): ViewerLease | null {
    try { return ws.deserializeAttachment() as ViewerLease | null; } catch { return null; }
  }
  private leases(): ViewerLease[] {
    return this.ctx.getWebSockets().flatMap((ws) => { const lease = this.lease(ws); return lease ? [lease] : []; });
  }
  private snapshot(ws: WebSocket): void {
    const lease = this.lease(ws);
    if (!lease || lease.expiresAt <= Date.now()) return;
    try {
      ws.send(JSON.stringify({ type: "workspace.presence", version: 1, scope: lease.scope,
        renewAfterMs: VIEW_RENEW_MS, participants: workspaceViewers(this.leases(), Date.now()) }));
    } catch { ws.serializeAttachment(null); }
  }
  private broadcast(): void { for (const ws of this.ctx.getWebSockets()) this.snapshot(ws); }
  private async schedule(): Promise<void> {
    const now = Date.now();
    const deadlines = this.leases().flatMap((s) => [s.expiresAt, s.viewingUntil]).filter((t) => t > now);
    if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines));
    else await this.ctx.storage.deleteAlarm();
  }
}
