import { z } from "zod";
import type { StackAuthority, VerifiedAuthority } from "./auth";
import { decodeJSON, errorResponse, httpFailure, inputRequestId, parseInput, parseSocketSetup, readBoundedBody, INPUT_BYTES } from "./boundary";
import { identifier, timestamp } from "./contracts/common";
import { SocketSetupSchema, type SocketSetup } from "./contracts/requests";
import { API_TICKET_SECONDS, canonicalJSON, decodeBase64URL, encodeBase64URL, verifyTicket } from "./crypto";
import { OperationError } from "./errors";

export const SETUP_HEADER = "x-cmux-v2-setup";
const INTERNAL_HEADER = "x-cmux-v2-verified-authority";
export const AuthoritySchema = z.strictObject({
  environment: identifier, projectId: identifier, teamId: identifier, userId: identifier, verifiedAt: timestamp,
});
const AuthorizationSchema = z.strictObject({ authority: AuthoritySchema, expiresAt: timestamp, issueTicket: z.boolean() });
const InternalBodySchema = z.strictObject({ setup: SocketSetupSchema, input: z.unknown().optional() });
export type Authorization = z.infer<typeof AuthorizationSchema>;

export interface RoutingDependencies {
  environment: string;
  projectId: string;
  ticketKeys: Readonly<Record<string, string>>;
  stack: Pick<StackAuthority, "verify">;
  now: () => number;
  chargeOpen: (userId: string) => Promise<void>;
  dispatchTeam: (teamId: string, request: Request) => Promise<Response>;
}

const aliases: Readonly<Record<string, string>> = {
  "/v2/tickets": "ticket.request.v1",
  "/v2/challenges": "challenge.request.v1",
  "/v2/devices/register": "device.register.v1",
  "/v2/relay/token": "relay.request.v1",
};

/** Public requests never control the private headers passed through the DO binding. */
export async function routeControl(request: Request, dependencies: RoutingDependencies): Promise<Response> {
  let requestId = "unidentified";
  try {
    const url = new URL(request.url);
    const socket = url.pathname === "/v2/control/socket";
    const session = url.pathname === "/v2/control/session";
    const operation = url.pathname === "/v2/requests" || Object.hasOwn(aliases, url.pathname);
    if ((!socket && !session && !operation) || url.search) throw new OperationError("unsupported_method", 404);
    if (request.method !== (socket ? "GET" : "POST")) throw new OperationError("unsupported_method", 405);
    if (socket && request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new OperationError("invalid_request", 400);
    if (!socket && request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
      throw new OperationError("unsupported_media_type", 415);
    }
    let input: unknown;
    const setup = session ? parseSocketSetup(await readBoundedBody(request)) : readSetup(request);
    requestId = setup.requestId;
    if (operation) {
      input = await readBoundedBody(request);
      if (inputRequestId(input) !== requestId) throw new OperationError("invalid_request", 400);
      const expected = aliases[url.pathname];
      if (expected && (typeof input !== "object" || input === null || Reflect.get(input, "schemaId") !== expected)) {
        throw new OperationError("invalid_request", 400);
      }
    }
    const authorization = await authenticate(request.headers.get("authorization"), setup, dependencies);
    if (!operation) await dependencies.chargeOpen(authorization.authority.userId);
    // A fresh Request deliberately copies no caller headers, cookies or credentials.
    const headers = new Headers({
      "content-type": "application/json", [INTERNAL_HEADER]: JSON.stringify(authorization),
    });
    if (socket) {
      headers.set("upgrade", "websocket");
      headers.set(SETUP_HEADER, encodeBase64URL(new TextEncoder().encode(JSON.stringify(setup))));
    }
    const forwarded = new Request("https://iroh-v2.internal/" + (socket ? "socket" : session ? "session" : "request"), {
      method: socket ? "GET" : "POST", headers,
      ...(socket ? {} : { body: JSON.stringify({ setup, ...(operation ? { input } : {}) }) }),
    });
    return await dependencies.dispatchTeam(setup.device.identity.teamId, forwarded);
  } catch (error) {
    const failure = errorResponse(error, requestId).failure;
    console.log(JSON.stringify({ event: "iroh.control.failure", requestId, code: failure.code, status: failure.status, retryable: failure.retryable }));
    return httpFailure(error, requestId);
  }
}

function readSetup(request: Request): SocketSetup {
  const encoded = request.headers.get(SETUP_HEADER);
  if (!encoded) throw new OperationError("invalid_request", 400);
  if (encoded.length > Math.ceil(INPUT_BYTES * 4 / 3)) throw new OperationError("payload_too_large", 413);
  return parseSocketSetup(decodeJSON(decodeBase64URL(encoded)));
}

async function authenticate(header: string | null, setup: SocketSetup, dependencies: RoutingDependencies): Promise<Authorization> {
  const identity = setup.device.identity;
  if (identity.environment !== dependencies.environment || identity.projectId !== dependencies.projectId) throw new OperationError("environment_mismatch", 403);
  if (!header || header.length > 8208) throw new OperationError("unauthorized", 401);
  const now = dependencies.now();
  if (header.startsWith("IrohTicket ")) {
    const claims = await verifyTicket(header.slice(11), dependencies.ticketKeys, dependencies.environment, dependencies.projectId, now);
    if (canonicalJSON(identity) !== canonicalJSON(claims.identity) || setup.device.endpointId !== claims.endpointId || setup.device.identityGeneration !== claims.identityGeneration) {
      throw new OperationError("identity_mismatch", 403);
    }
    const authority: VerifiedAuthority = {
      environment: claims.identity.environment, projectId: claims.identity.projectId,
      teamId: claims.identity.teamId, userId: claims.identity.userId, verifiedAt: claims.issuedAt,
    };
    return { authority, expiresAt: claims.expiresAt, issueTicket: false };
  }
  if (!header.startsWith("Bearer ")) throw new OperationError("unauthorized", 401);
  const authority = await dependencies.stack.verify(header.slice(7), identity, now);
  return { authority, expiresAt: authority.verifiedAt + API_TICKET_SECONDS, issueTicket: true };
}

/** Reachable only through the private namespace binding, never a public proxy route. */
export async function readInternalRequest(request: Request) {
  const url = new URL(request.url);
  const socket = url.pathname === "/socket";
  if (url.origin !== "https://iroh-v2.internal" || request.method !== (socket ? "GET" : "POST") || !["/socket", "/session", "/request"].includes(url.pathname)) {
    throw new OperationError("unauthorized", 401);
  }
  const header = request.headers.get(INTERNAL_HEADER);
  if (!header || header.length > 2048) throw new OperationError("unauthorized", 401);
  let value: unknown;
  try { value = JSON.parse(header); } catch { throw new OperationError("unauthorized", 401); }
  const authorization = parseInput(AuthorizationSchema, value);
  const body = socket ? { setup: readSetup(request), input: undefined }
    : parseInput(InternalBodySchema, await readBoundedBody(request, INPUT_BYTES * 2 + 1024));
  return { path: url.pathname, ...authorization, ...body };
}

export function objectName(environment: string, projectId: string, subject: string): string {
  return JSON.stringify([environment, projectId, subject]);
}
