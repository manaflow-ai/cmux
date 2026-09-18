import type { StackAuthority } from "./auth";
import { encodeResponse, errorResponse, httpFailure, inputRequestId, parseInput, readBoundedBody } from "./boundary";
import { DashboardOpenSchema } from "./contracts/common";
import { DASHBOARD_AUTHORITY_HEADER, issueDashboardTicket, verifyDashboardTicket } from "./dashboard-auth";
import { OperationError } from "./errors";

interface Dependencies {
  environment: string; projectId: string; keys: Readonly<Record<string, string>>;
  currentKeyId: string; currentKey: string; allowedOrigins: readonly string[];
  stack: Pick<StackAuthority, "verify" | "canManageTeam">;
  now(): number;
  charge(userId: string, operation: "ticket.request" | "control.socket"): Promise<void>;
  dispatchTeam(teamId: string, request: Request): Promise<Response>;
  observe?(event: { event: string; requestId: string; code: string; status: number }): void;
}

/** Browser auth is verified before it can allocate a team socket. Tokens never enter URLs. */
export async function routeDashboard(request: Request, services: Dependencies): Promise<Response> {
  let requestId = "unidentified", approvedOrigin: string | null = null;
  const cors = (response: Response): Response => {
    // A WebSocket upgrade returned by a Durable Object has immutable headers.
    // Its Origin was checked before dispatch, and the handshake needs no CORS
    // decoration. Preserve the upgrade response and its selected protocol.
    if (!approvedOrigin || response.status === 101) return response;
    response.headers.set("access-control-allow-origin", approvedOrigin);
    response.headers.set("vary", "Origin");
    response.headers.set("cache-control", "no-store");
    return response;
  };
  try {
    const url = new URL(request.url), origin = request.headers.get("origin");
    if (!origin || !services.allowedOrigins.includes(origin)) throw new OperationError("permission_denied", 403);
    approvedOrigin = origin;
    if (url.search || !["/v2/dashboard/session", "/v2/dashboard/socket"].includes(url.pathname)) throw new OperationError("unsupported_method", 404);
    if (request.method === "OPTIONS") {
      if (url.pathname !== "/v2/dashboard/session" || request.headers.get("access-control-request-method") !== "POST") throw new OperationError("unsupported_method", 405);
      const headers = (request.headers.get("access-control-request-headers") ?? "").split(",").map(value => value.trim().toLowerCase()).filter(Boolean);
      if (headers.some(value => !["authorization", "content-type"].includes(value))) throw new OperationError("permission_denied", 403);
      return cors(new Response(null, { status: 204, headers: { "access-control-allow-methods": "POST", "access-control-allow-headers": "authorization, content-type", "access-control-max-age": "600" } }));
    }
    if (url.pathname === "/v2/dashboard/session") {
      if (request.method !== "POST") throw new OperationError("unsupported_method", 405);
      if (request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") throw new OperationError("unsupported_media_type", 415);
      const input = await readBoundedBody(request);
      requestId = inputRequestId(input);
      const setup = parseInput(DashboardOpenSchema, input);
      if (setup.environment !== services.environment || setup.projectId !== services.projectId) throw new OperationError("environment_mismatch", 403);
      const header = request.headers.get("authorization");
      if (!header?.startsWith("Bearer ") || header.length > 8208) throw new OperationError("unauthorized", 401);
      const authority = await services.stack.verify(header.slice(7), setup, services.now());
      await services.charge(authority.userId, "ticket.request");
      const canManageTeam = await services.stack.canManageTeam(authority);
      const ticket = await issueDashboardTicket({ authority, origin, clientInstanceId: setup.clientInstanceId, canManageTeam }, services.currentKeyId, services.currentKey);
      return cors(new Response(encodeResponse({ schemaId: "dashboard.ready.v1", requestId, ticket }), {
        headers: { "content-type": "application/json; charset=utf-8" },
      }));
    }
    if (request.method !== "GET" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new OperationError("invalid_request", 400);
    const protocolHeader = request.headers.get("sec-websocket-protocol");
    if (!protocolHeader || protocolHeader.length > 8256) throw new OperationError("unauthorized", 401);
    const protocols = protocolHeader.split(",").map(value => value.trim());
    if (protocols.length !== 2 || protocols[0] !== "cmux-v2-dashboard" || !protocols[1]?.startsWith("ticket.")) throw new OperationError("unauthorized", 401);
    const claims = await verifyDashboardTicket(protocols[1].slice(7), services.keys, services.environment, services.projectId, origin, services.now());
    await services.charge(claims.authority.userId, "control.socket");
    // A fresh internal request copies no browser headers or credential values.
    const forwarded = new Request("https://iroh-v2.internal/dashboard/socket", { headers: {
      upgrade: "websocket", [DASHBOARD_AUTHORITY_HEADER]: JSON.stringify(claims),
    } });
    return cors(await services.dispatchTeam(claims.authority.teamId, forwarded));
  } catch (error) {
    const failure = errorResponse(error, requestId).failure;
    services.observe?.({ event: "iroh.dashboard.failure", requestId, code: failure.code, status: failure.status });
    return cors(httpFailure(error, requestId));
  }
}
