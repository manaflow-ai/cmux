import type { DurableObjectNamespace, DurableObjectState } from "@cloudflare/workers-types";
import { StackAuthority, type StackConfiguration } from "./auth";
import { readBoundedBody, parseControlRequest, parseJSON, encodeResponse, httpFailure, inputRequestId } from "./boundary";
import { canonicalJSON, challengeSigningInput, hash, issueTicket, verifyDeviceSignature, verifyTicket } from "./crypto";
import { OperationError } from "./errors";
import { IdentitySchema, DeviceDescriptorSchema, type Identity } from "./contracts/common";
import { type ControlRequest } from "./contracts/requests";
import { type ControlResponse } from "./contracts/responses";

export interface Env {
  TEAM_CONTROL_PLANE: DurableObjectNamespace;
  STACK_API_URL: string;
  STACK_PROJECT_ID: string;
  STACK_PUBLISHABLE_KEY: string;
  API_TICKET_KEYS: string;
  ENVIRONMENT: string;
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function bearer(request: Request): string {
  const value = request.headers.get("authorization") ?? "";
  return value.startsWith("Bearer ") ? value.slice(7).trim() : "";
}

function identityHeader(request: Request): Identity | null {
  const value = request.headers.get("x-v2-identity");
  if (!value) return null;
  try {
    return IdentitySchema.parse(parseJSON(value, 4 * 1024));
  } catch {
    return null;
  }
}

function bodyIdentity(value: unknown): Identity | null {
  if (value === null || typeof value !== "object") return null;
  const device = Reflect.get(value, "device");
  if (device === undefined) return null;
  const parsed = DeviceDescriptorSchema.safeParse(device);
  return parsed.success ? parsed.data.identity : null;
}

function keyMap(raw: string): Readonly<Record<string, string>> {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid key map");
    const result: Record<string, string> = {};
    for (const [key, value] of Object.entries(parsed)) {
      if (!/^[A-Za-z0-9._-]{1,128}$/.test(key) || typeof value !== "string") throw new Error("invalid key map");
      result[key] = value;
    }
    if (Object.keys(result).length === 0) throw new Error("empty key map");
    return result;
  } catch {
    throw new Error("API_TICKET_KEYS must be a non-empty JSON object");
  }
}

function teamName(identity: Identity): string {
  return JSON.stringify([identity.environment, identity.projectId, identity.teamId]);
}

async function authenticate(request: Request, env: Env, identity: Identity): Promise<void> {
  const cachedTicket = request.headers.get("x-v2-ticket");
  if (cachedTicket) {
    const claims = await verifyTicket(cachedTicket, keyMap(env.API_TICKET_KEYS), env.ENVIRONMENT, env.STACK_PROJECT_ID, Date.now());
    if (canonicalJSON(claims.identity) !== canonicalJSON(identity)) throw new OperationError("identity_mismatch", 403);
    return;
  }
  if (!env.STACK_API_URL || !env.STACK_PROJECT_ID || !env.STACK_PUBLISHABLE_KEY) {
    throw new OperationError("upstream_unavailable", 503, true, 2_000);
  }
  const configuration: StackConfiguration = {
    environment: env.ENVIRONMENT,
    apiURL: env.STACK_API_URL,
    projectId: env.STACK_PROJECT_ID,
    publishableKey: env.STACK_PUBLISHABLE_KEY,
  };
  const token = bearer(request);
  if (!token) throw new OperationError("unauthorized", 401);
  try {
    await new StackAuthority(configuration).verify(token, identity, Date.now());
  } catch (error) {
    if (error instanceof OperationError) throw error;
    throw new OperationError("upstream_unavailable", 503, true, 2_000);
  }
}

/** One team/environment object. HTTP and WebSocket adapters call this same broker. */
export class TeamControlPlane {
  private initialized = false;

  constructor(private readonly ctx: DurableObjectState, private readonly env: Env) {}

  private async activate(): Promise<void> {
    if (this.initialized) return;
    await this.ctx.blockConcurrencyWhile(async () => {
      if (this.initialized) return;
      const version = await this.ctx.storage.get<number>("v2.schema");
      if (version !== undefined && version !== 1) throw new Error("iroh_v2_unsupported_schema");
      await this.ctx.storage.put("v2.schema", 1);
      this.initialized = true;
    });
  }

  async fetch(request: Request): Promise<Response> {
    await this.activate();
    if (request.method === "GET" && request.headers.get("upgrade")?.toLowerCase() === "websocket") {
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      pair[1].serializeAttachment({ openedAt: Date.now() });
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    if (request.method !== "POST") return json({ error: "unsupported_method" }, 405);
    const raw = await readBoundedBody(request);
    const input = parseControlRequest(raw);
    const response = await this.handle(input, request);
    return new Response(encodeResponse(response), { headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
  }

  private async handle(input: ControlRequest, request: Request): Promise<ControlResponse> {
    const requestId = inputRequestId(input);
    const identity = bodyIdentity(input) ?? identityHeader(request);
    if (!identity) throw new OperationError("invalid_request", 400);
    if (request.headers.get("x-v2-verified-user") !== identity.userId) throw new OperationError("unauthorized", 401);
    const revision = (await this.ctx.storage.get<number>("v2.revision")) ?? 0;
    switch (input.schemaId) {
      case "challenge.request.v1": {
        const nonce = crypto.randomUUID().replaceAll("-", "").padEnd(43, "0").slice(0, 43);
        const payloadHash = await hash(canonicalJSON(input.device));
        const expiresAt = Date.now() + 30 * 60 * 1000;
        const challengeId = crypto.randomUUID();
        await this.ctx.storage.put(`challenge:${identity.userId}:${identity.deviceId}`, { challengeId, nonce, payloadHash, expiresAt });
        await this.ctx.storage.put(`device:${identity.userId}:${identity.deviceId}`, input.device);
        return { schemaId: "challenge.result.v1", requestId, challenge: { challengeId, nonce, payloadHash, expiresAt } };
      }
      case "device.register.v1": {
        const key = `challenge:${identity.userId}:${identity.deviceId}`;
        const challenge = await this.ctx.storage.get<{ challengeId: string; nonce: string; payloadHash: string; expiresAt: number }>(key);
        if (!challenge) throw new OperationError("challenge_missing", 409);
        if (challenge.challengeId !== input.challengeId) throw new OperationError("challenge_replaced", 409);
        if (challenge.expiresAt <= Date.now()) throw new OperationError("challenge_expired", 409);
        if (challenge.nonce !== input.nonce || challenge.payloadHash !== await hash(canonicalJSON(input.device))) throw new OperationError("challenge_invalid", 400);
        await verifyDeviceSignature(input.device.endpointId, challengeSigningInput(input.device, input.challengeId, input.nonce), input.signature);
        const nextRevision = revision + 1;
        await this.ctx.storage.put(`device:${identity.userId}:${identity.deviceId}`, input.device);
        await this.ctx.storage.put("v2.revision", nextRevision);
        await this.ctx.storage.delete(key);
        return { schemaId: "device.registered.v1", requestId, device: { deviceRecordId: input.device.endpointId, descriptor: input.device, revision: nextRevision, revoked: false } };
      }
      case "ticket.request.v1": {
        const keys = keyMap(this.env.API_TICKET_KEYS);
        const [keyId, secret] = Object.entries(keys)[0]!;
        const stored = await this.ctx.storage.get<ReturnType<typeof DeviceDescriptorSchema.parse>>(`device:${identity.userId}:${identity.deviceId}`);
        if (!stored) throw new OperationError("device_not_enrolled", 409);
        return { schemaId: "ticket.result.v1", requestId, ticket: await issueTicket(stored, keyId, secret, Date.now()) };
      }
      case "directory.request.v1":
        return { schemaId: "directory.result.v1", requestId, directory: { teamId: identity.teamId, revision, devices: [], relayURLs: [], issuedAt: Date.now(), permissionExpiresAt: Date.now() + 60 * 60 * 1000, nextCursor: null } };
      case "session.goodbye.v1":
        return { schemaId: "operation.completed.v1", requestId, revision };
      default:
        return { schemaId: "operation.completed.v1", requestId, revision };
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return json({ ok: true, service: "cmux-iroh-v2", version: 2 });
    if (!url.pathname.startsWith("/v2/")) return json({ error: "unsupported_method" }, 404);
    try {
      if (url.pathname === "/v2/control/socket" && request.method === "GET") {
        if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new OperationError("unsupported_media_type", 415);
        const identity = identityHeader(request);
        if (!identity) throw new OperationError("invalid_request", 400);
        await authenticate(request, env, identity);
        const stub = env.TEAM_CONTROL_PLANE.get(env.TEAM_CONTROL_PLANE.idFromName(teamName(identity)));
        const headers = new Headers(request.headers);
        headers.set("x-v2-verified-user", identity.userId);
        return stub.fetch(new Request(request.url, { method: "GET", headers })) as unknown as Response;
      }
      if (request.method !== "POST") throw new OperationError("unsupported_method", 405);
      const body = await readBoundedBody(request);
      const identity = bodyIdentity(body) ?? identityHeader(request);
      if (!identity) throw new OperationError("invalid_request", 400);
      await authenticate(request, env, identity);
      const input = parseControlRequest(body);
      const stub = env.TEAM_CONTROL_PLANE.get(env.TEAM_CONTROL_PLANE.idFromName(teamName(identity)));
      const headers = new Headers(request.headers);
      headers.set("x-v2-verified-user", identity.userId);
      headers.set("x-v2-identity", canonicalJSON(identity));
      return stub.fetch(new Request(request.url, { method: "POST", headers, body: JSON.stringify(input) })) as unknown as Response;
    } catch (error) {
      return httpFailure(error);
    }
  },
};
