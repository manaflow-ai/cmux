import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { TeamBroker, type BrokerResult, type BrokerSession } from "./broker";
import { encodeResponse, errorResponse, httpFailure, inputOperation, inputRequestId, parseControlRequest, parseJSON } from "./boundary";
import { IdentitySchema, endpointID, identifier, revision, timestamp } from "./contracts/common";
import type { ControlResponse } from "./contracts/responses";
import { identityKey, issueTicket } from "./crypto";
import { acknowledgeDelivery, DeliveryStateSchema, deliveryUsage, emptyDeliveryState, prepareDelivery } from "./delivery";
import { environmentScope, runtime, type Environment } from "./environment";
import { OperationError, publicError } from "./errors";
import { AuthoritySchema, objectName, readInternalRequest } from "./routing";
import { applyStorageMigrations } from "./storage/migrations";
import { TeamStore } from "./storage/team-store";
import type { UsageOperation } from "./storage/user-usage";
import { unwrap } from "./user-usage-object";

const SessionSchema = z.strictObject({
  sessionId: identifier, identity: IdentitySchema, endpointId: endpointID, identityGeneration: revision,
  authority: AuthoritySchema, expiresAt: timestamp,
});
const AttachmentSchema = z.strictObject({
  version: z.literal(1), session: SessionSchema, deviceKey: z.string().regex(/^[a-f0-9]{64}$/),
  delivery: DeliveryStateSchema, outputRevision: revision, closed: z.boolean(),
});
type Attachment = z.infer<typeof AttachmentSchema>;
const TEAM_SOCKET_LIMIT = 4096;

/** No presence timer, credential timer or cleanup alarm runs in this object. */
export class TeamControl extends DurableObject<Environment> {
  private brokers = new Map<string, TeamBroker>();
  private opening = new Set<string>();
  private queues = new Map<WebSocket, { tail: Promise<void>; count: number }>();
  private queuedBytes = 0;

  constructor(ctx: DurableObjectState, env: Environment) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => { applyStorageMigrations(ctx.storage); });
    // Native WebSocket ping/pong is handled by Cloudflare without waking us.
  }

  async fetch(request: Request): Promise<Response> {
    let requestId = "unidentified";
    try {
      const incoming = await readInternalRequest(request);
      requestId = incoming.setup.requestId;
      const broker = this.broker(incoming.authority.teamId);
      if (incoming.path === "/request") {
        const session = await broker.authorizeHTTP(incoming.setup, incoming.input, incoming.authority, incoming.expiresAt);
        const result = await broker.execute(session, incoming.input);
        this.scheduleChanges(result, session.identity.teamId);
        return this.json(result.response);
      }
      const result = await broker.open(incoming.setup, incoming.authority, incoming.expiresAt, incoming.issueTicket);
      if (!result.session) throw new OperationError("internal_error", 500);
      this.scheduleChanges(result, incoming.authority.teamId);
      if (incoming.path === "/session") return this.json(result.response);
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new OperationError("invalid_request", 400);
      if (this.ctx.getWebSockets().length >= TEAM_SOCKET_LIMIT) throw new OperationError("rate_limited", 429, true, 5000);
      const session = result.session;
      const deviceKey = await identityKey(incoming.setup.device);
      this.opening.add(session.sessionId);
      try {
        await this.reserveSocket(session, deviceKey);
        const pair = new WebSocketPair();
        const client = pair[0], server = pair[1];
        this.ctx.acceptWebSocket(server, ["user:" + session.identity.userId, "device:" + deviceKey]);
        this.save(server, { version: 1, session, deviceKey, delivery: emptyDeliveryState(), outputRevision: 0, closed: false });
        try { await this.enqueue(server, 0, () => this.send(server, result.response)); }
        catch (error) { this.close(server, "slow_consumer"); throw error; }
        // The replacement is accepted and ready before any previous socket closes.
        for (const old of this.ctx.getWebSockets("device:" + deviceKey)) if (old !== server) this.close(old, "session_replaced");
        return new Response(null, { status: 101, webSocket: client });
      } finally { this.opening.delete(session.sessionId); }
    } catch (error) {
      const failure = publicError(error);
      console.log(JSON.stringify({ event: "iroh.team.failure", requestId, code: failure.code, status: failure.status, retryable: failure.retryable }));
      return httpFailure(error, requestId);
    }
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const size = typeof message === "string" ? new TextEncoder().encode(message).byteLength : message.byteLength;
    try {
      await this.enqueue(ws, size, async () => {
        const attachment = this.load(ws);
        if (attachment.closed) return;
        let input: unknown;
        const started = Date.now();
        let status = 200;
        let code = "ok";
        try {
          if (typeof message !== "string") throw new OperationError("invalid_request", 400);
          input = parseJSON(message);
          if (typeof input === "object" && input !== null && Reflect.get(input, "schemaId") === "session.ack.v1") {
            unwrap(await this.user(attachment.session.identity.userId).consume(attachment.session.identity.userId, "session.ack"));
            const request = parseControlRequest(input);
            if (request.schemaId !== "session.ack.v1") throw new OperationError("invalid_request", 400);
            const next = acknowledgeDelivery(attachment.delivery, request.sequence, request.token);
            const usage = deliveryUsage(next);
            if (next !== attachment.delivery) {
              const nextRevision = attachment.outputRevision + 1;
              unwrap(await this.user(attachment.session.identity.userId).setOutput(attachment.session.identity.userId, attachment.session.sessionId, nextRevision, usage.bytes, usage.messages));
              if (!this.load(ws).closed) this.save(ws, { ...attachment, delivery: next, outputRevision: nextRevision });
            }
            return; // No ack response and no idle traffic.
          }
          const result = await this.broker(attachment.session.identity.teamId).execute(attachment.session, input);
          if (result.session && !this.load(ws).closed) this.save(ws, { ...this.load(ws), session: result.session });
          await this.send(ws, result.response);
          this.scheduleChanges(result, attachment.session.identity.teamId);
          if (result.close) this.close(ws, "goodbye");
        } catch (error) {
          const failure = errorResponse(error, inputRequestId(input));
          status = failure.failure.status; code = failure.failure.code;
          try { await this.send(ws, failure.body); } catch { this.close(ws, "slow_consumer"); }
          if (["device_revoked", "team_access_revoked", "identity_mismatch", "key_replacement_required"].includes(code)) this.close(ws, code);
        } finally {
          console.log(JSON.stringify({ event: "iroh.socket.operation", environment: this.env.ENVIRONMENT, operation: inputOperation(input), status, code, durationMs: Date.now() - started }));
        }
      });
    } catch { this.close(ws, size > 16 * 1024 ? "payload_too_large" : "input_capacity"); }
  }

  async webSocketClose(ws: WebSocket): Promise<void> { await this.releaseClosed(ws); }
  async webSocketError(ws: WebSocket): Promise<void> { this.close(ws, "transport_error"); await this.releaseClosed(ws); }

  /** Used only under quota pressure to recover reservations left by a terminated invocation. */
  liveSessionIds(teamId: string, userId: string, sessionIds: string[]): string[] {
    this.broker(teamId);
    if (sessionIds.length > 501) throw new OperationError("invalid_request", 400);
    const candidates = new Set(sessionIds);
    const live = new Set([...this.opening].filter(id => candidates.has(id)));
    for (const ws of this.ctx.getWebSockets("user:" + identifier.parse(userId))) {
      const attachment = this.load(ws);
      if (ws.readyState !== WebSocket.CLOSED && candidates.has(attachment.session.sessionId)) live.add(attachment.session.sessionId);
    }
    return [...live];
  }

  private broker(teamId: string): TeamBroker {
    const scope = environmentScope(this.env);
    const expected = this.env.TEAM_CONTROL.idFromName(objectName(scope.environment, scope.projectId, teamId));
    if (!this.ctx.id.equals(expected)) throw new OperationError("identity_mismatch", 403);
    let broker = this.brokers.get(teamId);
    if (!broker) {
      const services = runtime(this.env);
      broker = new TeamBroker({
        store: new TeamStore(this.ctx.storage, { ...scope, teamId }, { initialize: false }),
        ownership: services.ownership, relays: services.relays, now: () => Math.floor(Date.now() / 1000),
        charge: async (userId, operation) => { unwrap(await this.user(userId).consume(userId, operation as UsageOperation)); },
        issueTicket: (device, now) => issueTicket(device, services.currentKeyId, services.currentKey, now),
        verifyStack: (token, identity, now) => services.stack.verify(token, identity, now),
        canManageTeam: authority => services.stack.canManageTeam(authority),
        verifyTeamMember: (teamId, userId) => services.stack.verifyTeamMember(teamId, userId),
      });
      this.brokers.set(teamId, broker);
    }
    return broker;
  }

  private user(userId: string) {
    return this.env.USER_USAGE.getByName(objectName(this.env.ENVIRONMENT, this.env.STACK_PROJECT_ID, userId));
  }

  private async reserveSocket(session: BrokerSession, deviceKey: string) {
    const user = this.user(session.identity.userId);
    const input = { userId: session.identity.userId, teamId: session.identity.teamId, sessionId: session.sessionId, deviceKey };
    const reservation = await user.reserveSocket(input);
    if (reservation.ok || reservation.code !== "rate_limited") return unwrap(reservation);
    const previous = unwrap(await user.listSocketReservations(input.userId));
    const groups = new Map<string, typeof previous>();
    for (const row of previous) {
      const records = groups.get(row.teamId) ?? [];
      records.push(row); groups.set(row.teamId, records);
    }
    // At most 501 reservations; the user quota has already rejected more work.
    for (const [teamId, records] of groups) {
      const ids = records.map(row => row.sessionId);
      const owner = this.env.TEAM_CONTROL.getByName(objectName(this.env.ENVIRONMENT, this.env.STACK_PROJECT_ID, teamId));
      const live = new Set(teamId === input.teamId ? this.liveSessionIds(teamId, input.userId, ids) : await owner.liveSessionIds(teamId, input.userId, ids));
      for (const record of records) if (!live.has(record.sessionId)) unwrap(await user.releaseSocket(input.userId, record.sessionId));
    }
    unwrap(await user.reserveSocket(input));
  }

  private async send(ws: WebSocket, response: ControlResponse): Promise<void> {
    const attachment = this.load(ws);
    if (attachment.closed) return;
    const next = prepareDelivery(attachment.delivery, response);
    const outputRevision = attachment.outputRevision + 1;
    unwrap(await this.user(attachment.session.identity.userId).setOutput(attachment.session.identity.userId, attachment.session.sessionId, outputRevision, next.bytes, next.messages));
    if (this.load(ws).closed) return;
    this.save(ws, { ...attachment, delivery: next.state, outputRevision });
    // The budget RPC yields. Re-check authority before private data leaves us.
    if (response.schemaId === "session.ready.v1") {
      const broker = this.broker(attachment.session.identity.teamId);
      if (broker.dependencies.store.getDevice(attachment.session.identity)) broker.requiredDevice(attachment.session);
      if (attachment.session.expiresAt <= Math.floor(Date.now() / 1000)) throw new OperationError("ticket_expired", 401, true);
    }
    if (["directory.result.v1", "relay.result.v1", "ticket.result.v1", "device.registered.v1"].includes(response.schemaId)) {
      const broker = this.broker(attachment.session.identity.teamId);
      broker.requiredDevice(attachment.session);
      if (attachment.session.expiresAt <= Math.floor(Date.now() / 1000)) throw new OperationError("ticket_expired", 401, true);
      if (response.schemaId === "directory.result.v1" && broker.dependencies.store.readRevision() !== response.directory.revision) throw new OperationError("resync_required", 409, true);
    }
    ws.send(next.text);
  }

  private scheduleChanges(result: BrokerResult, teamId: string) {
    if (result.changed) this.ctx.waitUntil(this.broadcast(teamId, result.changed).catch(() => {
      console.log(JSON.stringify({ event: "iroh.directory.delivery_failed", environment: this.env.ENVIRONMENT }));
    }));
  }

  private async broadcast(teamId: string, change: NonNullable<BrokerResult["changed"]>) {
    const sockets = this.ctx.getWebSockets();
    for (let start = 0; start < sockets.length; start += 16) {
      await Promise.allSettled(sockets.slice(start, start + 16).map(ws => this.enqueue(ws, 0, async () => {
        const attachment = this.load(ws);
        if (attachment.closed || attachment.session.expiresAt <= Math.floor(Date.now() / 1000)) return;
        const broker = this.broker(teamId);
        const record = broker.dependencies.store.getDevice(attachment.session.identity);
        // Broadcast revision invalidations, never another user's device record.
        if (record && change.revokedDeviceRecordId === record.deviceRecordId) {
          await this.send(ws, { schemaId: "device.revoked.v1", teamId, deviceRecordId: record.deviceRecordId, revision: change.revision });
          this.close(ws, "device_revoked");
        } else {
          try { broker.requiredDevice(attachment.session); }
          catch (error) {
            await this.send(ws, errorResponse(error, "unsolicited").body);
            this.close(ws, "device_revoked"); return;
          }
          await this.send(ws, { schemaId: "directory.changed.v1", teamId, revision: change.revision });
        }
      }).catch(() => { this.close(ws, "slow_consumer"); })));
    }
  }

  private enqueue(ws: WebSocket, bytes: number, action: () => Promise<void>): Promise<void> {
    const entry = this.queues.get(ws) ?? { tail: Promise.resolve(), count: 0 };
    if (bytes > 16 * 1024 || entry.count >= 32 || this.queuedBytes + bytes > 4 * 1024 * 1024) return Promise.reject(new OperationError("rate_limited", 429, true, 1000));
    entry.count++; this.queuedBytes += bytes;
    const result = entry.tail.then(action);
    const tail = result.catch(() => {}).finally(() => {
      entry.count--; this.queuedBytes -= bytes;
      if (entry.count === 0) this.queues.delete(ws);
    });
    entry.tail = tail;
    this.queues.set(ws, entry);
    return result;
  }

  private load(ws: WebSocket): Attachment { return AttachmentSchema.parse(ws.deserializeAttachment()); }
  private save(ws: WebSocket, attachment: Attachment) {
    const parsed = AttachmentSchema.parse(attachment);
    if (new TextEncoder().encode(JSON.stringify(parsed)).byteLength > 15 * 1024) throw new OperationError("storage_limit", 507);
    ws.serializeAttachment(parsed);
  }
  private close(ws: WebSocket, reason: string) {
    try {
      const attachment = this.load(ws);
      if (!attachment.closed) this.save(ws, { ...attachment, closed: true });
      const code = reason === "payload_too_large" ? 1009
        : ["input_capacity", "slow_consumer"].includes(reason) ? 1013
        : ["device_revoked", "team_access_revoked", "identity_mismatch", "key_replacement_required"].includes(reason) ? 1008
        : reason === "transport_error" ? 1011 : 1000;
      ws.close(code, reason);
    } catch { /* The close/error event releases the reservation. */ }
  }
  private async releaseClosed(ws: WebSocket) {
    try {
      const attachment = this.load(ws);
      this.save(ws, { ...attachment, closed: true });
      unwrap(await this.user(attachment.session.identity.userId).releaseSocket(attachment.session.identity.userId, attachment.session.sessionId));
    } catch (error) {
      console.log(JSON.stringify({ event: "iroh.socket.release_failed", environment: this.env.ENVIRONMENT, code: publicError(error).code }));
    }
  }
  private json(response: ControlResponse) {
    return new Response(encodeResponse(response), { headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
  }
}
