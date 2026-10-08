import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { AccountBroker, AccountResyncError, type AccountResult, type AccountSession } from "./account-broker";
import { hash } from "./crypto";
import { errorResponse, httpFailure, inputRequestId, parseJSON } from "./boundary";
import { accountOperation, accountResponse, type AccountResponse } from "./contracts/account";
import { IdentitySchema, endpointID, identifier, revision, timestamp, type Identity } from "./contracts/common";
import { environmentScope, runtime, type Environment } from "./environment";
import { failureDiagnostics, OperationError, publicError } from "./errors";
import { observe } from "./observability";
import { accountObjectName, objectName, readInternalRequest } from "./routing";
import { AccountStore, installationKey } from "./storage/account-store";

export const ACCOUNT_SOCKET_LIMIT = 32;
const OUTPUT_BYTES = 64 * 1024;

const AttachmentSchema = z.strictObject({
  version: z.literal(1),
  session: z.strictObject({
    sessionId: identifier, userId: identifier, identity: IdentitySchema, endpointId: endpointID,
    identityGeneration: revision, expiresAt: timestamp,
  }),
  closed: z.boolean(),
});
type Attachment = z.infer<typeof AttachmentSchema>;

/** Encodes and validates an account frame; team responses never pass through here. */
export function encodeAccountResponse(response: AccountResponse): string {
  const parsed = accountResponse.safeParse(response);
  if (!parsed.success) throw new OperationError("internal_error", 500, true);
  const text = JSON.stringify(parsed.data);
  if (new TextEncoder().encode(text).byteLength > OUTPUT_BYTES) throw new OperationError("internal_error", 500, true);
  return text;
}

/** Codes that end an account socket: its ticket or its Mac's team record no longer admits it. */
const CLOSING_CODES: ReadonlySet<string> = new Set(["ticket_expired", "device_revoked", "identity_mismatch", "key_replacement_required", "device_not_enrolled", "permission_denied"]);
export function closesAccountSocket(code: string): boolean { return CLOSING_CODES.has(code); }

/** Fixed-length socket tag (Workers tags are at most 256 characters; an app namespace alone may be 255). */
export async function installationTag(key: string): Promise<string> {
  return "installation:" + await hash(key);
}

/**
 * One object per Stack user: the Macs that user published from any team.
 * It holds no device authority of its own. Every directory read and every
 * team-change notice is checked against the owning TeamControl record, and
 * the requesting user comes only from the Worker's verified ticket claims.
 */
export class AccountControl extends DurableObject<Environment> {
  private readonly store: AccountStore;
  private brokers = new Map<string, AccountBroker>();

  private initialized = false;

  constructor(ctx: DurableObjectState, env: Environment) {
    super(ctx, env);
    // Storage is created lazily by the first account request, so a team
    // notice for a user who never used the account directory writes nothing.
    this.store = new AccountStore(ctx.storage, { initialize: false });
  }

  /** Synchronous, so no request can observe a half-created schema. */
  private ready(): void {
    if (this.initialized) return;
    this.store.initialize();
    this.initialized = true;
  }

  /** Overridden only by the runtime suite, which cannot open 32 live sockets cheaply. */
  protected socketLimit(): number { return ACCOUNT_SOCKET_LIMIT; }

  async fetch(request: Request): Promise<Response> {
    let requestId = "unidentified", stage = "parse", operation = "none";
    let userId: string | null = null;
    try {
      const incoming = await readInternalRequest(request);
      requestId = incoming.setup.requestId;
      // Account routes accept only ticket authority; a Stack token never reaches here.
      if (incoming.issueTicket || incoming.path === "/session") throw new OperationError("unauthorized", 401);
      const broker = this.broker(incoming.authority.userId);
      userId = incoming.authority.userId;
      this.ready();
      stage = "charge";
      this.store.consumeToken(Date.now());
      if (incoming.path === "/request") {
        operation = accountOperation(incoming.input);
        stage = "authorize";
        const { session } = await broker.authorize(incoming.setup, incoming.input, incoming.authority, incoming.expiresAt);
        stage = "execute";
        const result = await broker.execute(session, incoming.input);
        this.scheduleChanged(incoming.authority.userId, result, null);
        return this.json(result.response);
      }
      stage = "accept";
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new OperationError("invalid_request", 400);
      this.admitSocket();
      stage = "authorize";
      const { session } = await broker.authorize(incoming.setup, undefined, incoming.authority, incoming.expiresAt);
      stage = "ready";
      const tag = await installationTag(installationKey(session.identity));
      await broker.requireRequester(session);
      const pair = new WebSocketPair();
      const client = pair[0], server = pair[1];
      this.ctx.acceptWebSocket(server, [tag]);
      this.save(server, { version: 1, session, closed: false });
      server.send(encodeAccountResponse({ schemaId: "account.ready.v1", requestId, sessionId: session.sessionId, revision: this.store.readRevision() }));
      for (const old of this.ctx.getWebSockets(tag)) if (old !== server) this.close(old, "session_replaced");
      return new Response(null, { status: 101, webSocket: client });
    } catch (error) {
      if (error instanceof AccountResyncError && error.changed !== undefined && userId !== null) this.broadcast(userId, error.changed, null);
      const failure = publicError(error);
      observe(this.ctx, this.env, { event: "iroh.account.failure", environment: this.env.ENVIRONMENT, requestId, code: failure.code, status: failure.status,
        retryable: failure.retryable, stage, operation, ...failureDiagnostics(error) });
      return httpFailure(error, requestId);
    }
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    let attachment: Attachment;
    try { attachment = this.load(ws); } catch { return; }
    if (attachment.closed) return;
    let input: unknown;
    try {
      if (typeof message !== "string") throw new OperationError("invalid_request", 400);
      input = parseJSON(message);
      this.ready();
      this.store.consumeToken(Date.now());
      const result = await this.broker(attachment.session.userId).execute(attachment.session, input);
      this.send(ws, result.response);
      this.scheduleChanged(attachment.session.userId, result, ws);
    } catch (error) {
      const failure = errorResponse(error, inputRequestId(input));
      try { this.send(ws, failure.body); } catch { this.close(ws, "slow_consumer"); }
      if (error instanceof AccountResyncError && error.changed !== undefined) this.broadcast(attachment.session.userId, error.changed, null);
      if (closesAccountSocket(failure.failure.code)) this.close(ws, failure.failure.code);
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> { this.markClosed(ws); }
  async webSocketError(ws: WebSocket): Promise<void> { this.close(ws, "transport_error"); }

  /**
   * TeamControl's notice that one of this user's Mac records changed in
   * `teamId` (registration, metadata or revocation). Re-checks the rows for
   * that record or installation, tells this user's account sockets, and closes
   * an account socket whose Mac its team no longer admits, as the team path
   * closes a revoked team socket.
   */
  async teamChanged(userId: string, teamId: string, deviceRecordId: string, identity: Identity): Promise<void> {
    identifier.parse(teamId); identifier.parse(deviceRecordId);
    const parsed = IdentitySchema.parse(identity);
    const broker = this.broker(userId);
    if (parsed.userId !== userId || parsed.teamId !== teamId) throw new OperationError("identity_mismatch", 403);
    if (!this.initialized && !this.store.exists()) return;
    this.ready();
    let failure: unknown = null;
    try {
      const changed = await broker.teamChanged(teamId, deviceRecordId, parsed);
      if (changed !== null) this.broadcast(userId, changed, null);
    } catch (error) { failure = error; }
    // The socket check runs whatever happened to the row update above.
    for (const ws of this.ctx.getWebSockets(await installationTag(installationKey(parsed)))) {
      let attachment: Attachment;
      try { attachment = this.load(ws); } catch { continue; }
      if (attachment.closed || attachment.session.identity.teamId !== teamId) continue;
      let revoked: OperationError | null;
      try { revoked = await broker.socketRevocation(attachment.session); }
      catch (error) { failure ??= error; continue; }
      if (!revoked) continue;
      try { this.send(ws, errorResponse(revoked, "unsolicited").body); } catch { /* closing anyway */ }
      this.close(ws, revoked.code);
    }
    // Surfacing the failure lets TeamControl's bounded retry try again.
    if (failure !== null) throw failure;
  }

  private broker(userId: string): AccountBroker {
    identifier.parse(userId);
    const scope = environmentScope(this.env);
    if (!this.ctx.id.equals(this.env.ACCOUNT_CONTROL.idFromName(accountObjectName(scope.environment, scope.projectId, userId)))) {
      throw new OperationError("identity_mismatch", 403);
    }
    let broker = this.brokers.get(userId);
    if (!broker) {
      const services = runtime(this.env);
      broker = new AccountBroker({
        store: this.store, userId, now: () => Math.floor(Date.now() / 1000),
        relayURLs: services.relays.configuration.relayURLs,
        teamRecords: (teamId: string, identities: Identity[]) => this.env.TEAM_CONTROL
          .getByName(objectName(scope.environment, scope.projectId, teamId)).accountMacRecords(teamId, identities),
      });
      this.brokers.set(userId, broker);
    }
    return broker;
  }

  private scheduleChanged(userId: string, result: AccountResult, origin: WebSocket | null): void {
    if (result.changed === undefined) return;
    try { this.broadcast(userId, result.changed, origin); }
    catch { observe(this.ctx, this.env, { event: "iroh.account.delivery_failed", environment: this.env.ENVIRONMENT }); }
  }

  /** Sockets whose ticket lapsed hold no authority; reclaim their slots before refusing a new one. */
  private admitSocket(): void {
    if (this.ctx.getWebSockets().length < this.socketLimit()) return;
    const now = Math.floor(Date.now() / 1000);
    for (const ws of this.ctx.getWebSockets()) {
      let expired = true;
      try { const attachment = this.load(ws); expired = attachment.closed || attachment.session.expiresAt <= now; } catch { /* unreadable: reclaim */ }
      if (expired) this.close(ws, "ticket_expired");
    }
    const live = this.ctx.getWebSockets().filter(ws => { try { return !this.load(ws).closed; } catch { return false; } });
    if (live.length >= this.socketLimit()) throw new OperationError("rate_limited", 429, true, 5000);
  }

  /** Revision invalidations only; a socket re-reads the directory under its own authority. */
  private broadcast(userId: string, revision: number, origin: WebSocket | null): void {
    const now = Math.floor(Date.now() / 1000);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === origin) continue;
      try {
        const attachment = this.load(ws);
        if (attachment.closed || attachment.session.expiresAt <= now) continue;
        this.send(ws, { schemaId: "account.changed.v1", userId, revision });
      } catch { this.close(ws, "slow_consumer"); }
    }
  }

  private send(ws: WebSocket, response: AccountResponse): void {
    const attachment = this.load(ws);
    if (attachment.closed) return;
    // Like the team socket, results that carry device records leave only under
    // a ticket that is still valid when the frame is sent.
    if (response.schemaId !== "error.v1" && response.schemaId !== "account.changed.v1"
      && attachment.session.expiresAt <= Math.floor(Date.now() / 1000)) throw new OperationError("ticket_expired", 401, true);
    ws.send(encodeAccountResponse(response));
  }

  private load(ws: WebSocket): Attachment { return AttachmentSchema.parse(ws.deserializeAttachment()); }
  private save(ws: WebSocket, attachment: Attachment & { session: AccountSession }): void {
    ws.serializeAttachment(AttachmentSchema.parse(attachment));
  }
  private markClosed(ws: WebSocket): void {
    try { this.save(ws, { ...this.load(ws), closed: true }); } catch { /* already gone */ }
  }
  private close(ws: WebSocket, reason: string): void {
    this.markClosed(ws);
    const code = closesAccountSocket(reason) && reason !== "ticket_expired" ? 1008
      : reason === "slow_consumer" ? 1013 : reason === "transport_error" ? 1011 : 1000;
    try { ws.close(code, reason); } catch { /* already closed */ }
  }
  private json(response: AccountResponse): Response {
    return new Response(encodeAccountResponse(response), { headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
  }
}
