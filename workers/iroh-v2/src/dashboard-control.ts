import { z } from "zod";
import { errorResponse, httpFailure, inputOperation, inputRequestId, parseControlRequest, parseJSON } from "./boundary";
import type { BrokerResult, TeamBroker } from "./broker";
import type { ControlResponse } from "./contracts/responses";
import { identifier, revision } from "./contracts/common";
import { canonicalJSON, hash } from "./crypto";
import { DASHBOARD_AUTHORITY_HEADER, DashboardClaimsSchema, type DashboardClaims } from "./dashboard-auth";
import { acknowledgeDelivery, DeliveryStateSchema, deliveryUsage, emptyDeliveryState, prepareDelivery } from "./delivery";
import type { Environment } from "./environment";
import { OperationError } from "./errors";
import { observe } from "./observability";
import { unwrap, type UserUsage } from "./user-usage-object";

const AttachmentSchema = z.strictObject({
  kind: z.literal("dashboard"), sessionId: identifier, claims: DashboardClaimsSchema,
  deviceKey: z.string().regex(/^[a-f0-9]{64}$/), delivery: DeliveryStateSchema,
  outputRevision: revision, notifiedRevision: revision, closed: z.boolean(),
});
type Attachment = z.infer<typeof AttachmentSchema>;
type Services = {
  broker(teamId: string): TeamBroker;
  user(userId: string): DurableObjectStub<UserUsage>;
  reserve(session: { sessionId: string; identity: { teamId: string; userId: string } }, deviceKey: string): Promise<unknown>;
  enqueue(ws: WebSocket, bytes: number, action: () => Promise<void>): Promise<void>;
  changed(result: BrokerResult, teamId: string): void;
  opening: Set<string>;
};

/** Browser sockets live in the existing team DO and share its queues and user budgets. */
export class DashboardControl {
  constructor(private readonly ctx: DurableObjectState, private readonly env: Environment, private readonly services: Services) {}

  owns(ws: WebSocket): boolean { return ws.deserializeAttachment()?.kind === "dashboard"; }

  async fetch(request: Request): Promise<Response> {
    const requestId = crypto.randomUUID();
    try {
      if (request.url !== "https://iroh-v2.internal/dashboard/socket" || request.method !== "GET"
        || request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new OperationError("unauthorized", 401);
      const header = request.headers.get(DASHBOARD_AUTHORITY_HEADER);
      if (!header || header.length > 4096) throw new OperationError("unauthorized", 401);
      const claims = DashboardClaimsSchema.parse(JSON.parse(header));
      const broker = this.services.broker(claims.authority.teamId); // Checks this DO's actual namespace identity.
      this.assertLive(claims);
      if (this.ctx.getWebSockets().length >= 4096) throw new OperationError("rate_limited", 429, true, 5000);
      const sessionId = crypto.randomUUID();
      const deviceKey = await hash(canonicalJSON({ purpose: "dashboard-tab", userId: claims.authority.userId,
        teamId: claims.authority.teamId, origin: claims.origin, clientInstanceId: claims.clientInstanceId }));
      this.services.opening.add(sessionId);
      try {
        await this.services.reserve({ sessionId, identity: claims.authority }, deviceKey);
        this.assertLive(claims);
        const pair = new WebSocketPair(), client = pair[0], server = pair[1];
        this.ctx.acceptWebSocket(server, ["dashboard", "user:" + claims.authority.userId, "device:" + deviceKey]);
        this.save(server, { kind: "dashboard", sessionId, claims, deviceKey, delivery: emptyDeliveryState(),
          outputRevision: 0, notifiedRevision: 0, closed: false });
        try {
          await this.services.enqueue(server, 0, () => this.send(server, { schemaId: "dashboard.connected.v1", requestId,
            sessionId, teamRevision: broker.dependencies.store.readRevision(), expiresAt: claims.expiresAt }));
        } catch (error) { this.close(server, "slow_consumer"); throw error; }
        for (const old of this.ctx.getWebSockets("device:" + deviceKey)) if (old !== server) this.close(old, "session_replaced");
        observe(this.ctx, this.env, { event: "iroh.dashboard.opened", environment: this.env.ENVIRONMENT, requestId, status: 101 });
        return new Response(null, { status: 101, webSocket: client, headers: { "sec-websocket-protocol": "cmux-v2-dashboard" } });
      } finally { this.services.opening.delete(sessionId); }
    } catch (error) {
      const failure = errorResponse(error, requestId).failure;
      observe(this.ctx, this.env, { event: "iroh.dashboard.failure", requestId, code: failure.code, status: failure.status });
      return httpFailure(error, requestId);
    }
  }

  async message(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const bytes = typeof message === "string" ? new TextEncoder().encode(message).byteLength : message.byteLength;
    try {
      await this.services.enqueue(ws, bytes, async () => {
        const attachment = this.load(ws);
        if (attachment.closed) return;
        let input: unknown, status = 200, code = "ok";
        const started = Date.now();
        try {
          if (typeof message !== "string") throw new OperationError("invalid_request", 400);
          input = parseJSON(message);
          this.assertLive(attachment.claims);
          if (input !== null && typeof input === "object" && Reflect.get(input, "schemaId") === "session.ack.v1") {
            const userId = attachment.claims.authority.userId;
            unwrap(await this.services.user(userId).consume(userId, "session.ack"));
            const ack = parseControlRequest(input);
            if (ack.schemaId !== "session.ack.v1") throw new OperationError("invalid_request", 400);
            const delivery = acknowledgeDelivery(attachment.delivery, ack.sequence, ack.token);
            if (delivery !== attachment.delivery) {
              const usage = deliveryUsage(delivery), outputRevision = attachment.outputRevision + 1;
              unwrap(await this.services.user(userId).setOutput(userId, attachment.sessionId, outputRevision, usage.bytes, usage.messages));
              if (!this.load(ws).closed) this.save(ws, { ...attachment, delivery, outputRevision });
            }
            return;
          }
          const result = await this.services.broker(attachment.claims.authority.teamId).executeDashboard(attachment.claims, input);
          this.services.changed(result, attachment.claims.authority.teamId);
          await this.send(ws, result.response);
          if (result.close) this.close(ws, "goodbye");
        } catch (error) {
          const failure = errorResponse(error, inputRequestId(input));
          status = failure.failure.status; code = failure.failure.code;
          try { await this.send(ws, failure.body); } catch { this.close(ws, "slow_consumer"); }
          if (["ticket_expired", "team_access_revoked", "identity_mismatch"].includes(code)) this.close(ws, code);
        } finally {
          observe(this.ctx, this.env, { event: "iroh.dashboard.operation", environment: this.env.ENVIRONMENT,
            requestId: inputRequestId(input), operation: inputOperation(input), status, code, durationMs: Date.now() - started });
        }
      });
    } catch { this.close(ws, bytes > 16 * 1024 ? "payload_too_large" : "input_capacity"); }
  }

  async broadcast(teamId: string, changedRevision: number): Promise<void> {
    const sockets = this.ctx.getWebSockets("dashboard");
    for (let start = 0; start < sockets.length; start += 16) {
      await Promise.allSettled(sockets.slice(start, start + 16).map(ws => this.services.enqueue(ws, 0, async () => {
        const attachment = this.load(ws);
        if (attachment.closed || attachment.claims.expiresAt <= Math.floor(Date.now() / 1000)
          || changedRevision <= attachment.notifiedRevision) return;
        await this.send(ws, { schemaId: "directory.changed.v1", teamId, revision: changedRevision });
        const latest = this.load(ws);
        this.save(ws, { ...latest, notifiedRevision: Math.max(latest.notifiedRevision, changedRevision) });
      }).catch(() => this.close(ws, "slow_consumer"))));
    }
  }

  isLive(ws: WebSocket, candidates: Set<string>): string | null {
    const value = this.load(ws);
    return ws.readyState !== WebSocket.CLOSED && candidates.has(value.sessionId) ? value.sessionId : null;
  }

  async released(ws: WebSocket): Promise<void> {
    try {
      const attachment = this.load(ws);
      this.save(ws, { ...attachment, closed: true });
      const userId = attachment.claims.authority.userId;
      unwrap(await this.services.user(userId).releaseSocket(userId, attachment.sessionId));
    } catch { observe(this.ctx, this.env, { event: "iroh.dashboard.release_failed", status: 503 }); }
  }

  close(ws: WebSocket, reason: string): void {
    try {
      this.save(ws, { ...this.load(ws), closed: true });
      ws.close(reason === "payload_too_large" ? 1009 : ["input_capacity", "slow_consumer"].includes(reason) ? 1013
        : ["ticket_expired", "team_access_revoked", "identity_mismatch"].includes(reason) ? 1008 : 1000, reason);
    } catch { /* The close event releases the shared reservation. */ }
  }

  private async send(ws: WebSocket, response: ControlResponse): Promise<void> {
    const attachment = this.load(ws);
    if (attachment.closed) return;
    const next = prepareDelivery(attachment.delivery, response), outputRevision = attachment.outputRevision + 1;
    const userId = attachment.claims.authority.userId;
    unwrap(await this.services.user(userId).setOutput(userId, attachment.sessionId, outputRevision, next.bytes, next.messages));
    if (this.load(ws).closed) return;
    if (response.schemaId !== "error.v1") this.assertLive(attachment.claims);
    if (response.schemaId === "dashboard.directory.v1"
      && this.services.broker(attachment.claims.authority.teamId).dependencies.store.readRevision() !== response.directory.revision) {
      throw new OperationError("resync_required", 409, true);
    }
    this.save(ws, { ...attachment, delivery: next.state, outputRevision });
    ws.send(next.text);
  }

  private assertLive(claims: DashboardClaims): void {
    if (claims.authority.environment !== this.env.ENVIRONMENT || claims.authority.projectId !== this.env.STACK_PROJECT_ID) throw new OperationError("environment_mismatch", 403);
    if (claims.expiresAt <= Math.floor(Date.now() / 1000)) throw new OperationError("ticket_expired", 401, true);
  }
  private load(ws: WebSocket): Attachment { return AttachmentSchema.parse(ws.deserializeAttachment()); }
  private save(ws: WebSocket, value: Attachment): void { ws.serializeAttachment(AttachmentSchema.parse(value)); }
}
