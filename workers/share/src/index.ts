import { capabilityHash, verifyHostRequest, type ShareAuthEnv, type ShareAuthedUser } from "./auth";
import { ShareRoom } from "./shareRoom";
import { ShareOwnerIndex } from "./shareOwnerIndex";
import { normalizeShareId, shareExpiry, type ShareRoomMetadata } from "./state";
import { verifyViewerTicket, viewerTicketFromProtocols, type ShareViewerTicket } from "./ticket";
import { parseCreateRequest, readBoundedJson } from "./validate";

export { ShareOwnerIndex, ShareRoom };

export interface Env extends ShareAuthEnv {
  readonly SHARE_ROOM: DurableObjectNamespace<ShareRoom>;
  readonly SHARE_OWNER_INDEX: DurableObjectNamespace<ShareOwnerIndex>;
  readonly SHARE_WEB_ORIGIN?: string;
  readonly SHARE_ALLOWED_ORIGINS?: string;
  readonly SHARE_TICKET_PUBLIC_KEYS_JSON?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-share" });
    }
    if (url.pathname === "/v1/shares") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      return createShare(request, env);
    }
    const route = url.pathname.match(/^\/v1\/shares\/([^/]+)(?:\/(socket))?$/u);
    const shareId = route ? normalizeShareId(route[1] ?? "") : null;
    if (!shareId) return json({ error: "not_found" }, 404);
    if (route?.[2] === "socket") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return connectSocket(request, env, shareId);
    }
    if (request.method === "DELETE") return endShare(request, env, shareId);
    return json({ error: "method_not_allowed" }, 405);
  },
} satisfies ExportedHandler<Env>;

async function createShare(request: Request, env: Env): Promise<Response> {
  const owner = await verifyHostRequest(request, env);
  if (!owner) return json({ error: "unauthorized" }, 401);
  const body = await readBoundedJson(request);
  if (!body.ok) return json({ error: "invalid_request" }, body.status);
  const parsed = parseCreateRequest(body.value);
  if (!parsed) return json({ error: "invalid_request" }, 400);

  const shareId = randomBase64Url(16);
  const hostCapability = randomBase64Url(32);
  const createdAt = Date.now();
  const metadata: ShareRoomMetadata = {
    shareId,
    owner: {
      userId: owner.id,
      email: owner.email,
      displayName: owner.displayName,
    },
    hostCapabilityHash: await capabilityHash(hostCapability),
    workspaceId: parsed.workspaceId,
    workspaceTitle: parsed.workspaceTitle,
    createdAt,
    expiresAt: shareExpiry(createdAt),
    status: "active",
  };
  const ownerIndex = ownerIndexStub(env, owner.id);
  const reservation = await ownerIndex.reserve(shareId, metadata.expiresAt);
  if (!reservation.ok) return json({ error: reservation.error }, 429);
  const stub = roomStub(env, shareId);
  const result = await stub.create(metadata);
  if (!result.ok) {
    await ownerIndex.release(shareId);
    return json({ error: result.error }, 409);
  }
  const webOrigin = normalizedOrigin(env.SHARE_WEB_ORIGIN) ?? "https://cmux.com";
  return json({
    shareId,
    shareUrl: `${webOrigin}/share/${shareId}`,
    socketUrl: socketUrl(request.url, shareId),
    hostCapability,
    expiresAt: metadata.expiresAt,
  }, 201);
}

async function endShare(request: Request, env: Env, shareId: string): Promise<Response> {
  const owner = await verifyHostRequest(request, env);
  const capability = request.headers.get("x-cmux-share-capability")?.trim();
  if (!owner || !capability) return json({ error: "unauthorized" }, 401);
  const ended = await roomStub(env, shareId).end(owner.id, await capabilityHash(capability));
  return ended ? json({ ok: true }) : json({ error: "forbidden" }, 403);
}

async function connectSocket(request: Request, env: Env, shareId: string): Promise<Response> {
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "upgrade_required" }, 426);
  }
  const hostCapability = request.headers.get("x-cmux-share-capability")?.trim();
  const host = hostCapability ? await verifyHostRequest(request, env) : null;
  if (host && hostCapability) {
    return forwardSocket(request, env, shareId, "host", hostPrincipal(host), {
      "x-cmux-share-capability-hash": await capabilityHash(hostCapability),
    });
  }

  if (!originAllowed(request, env.SHARE_ALLOWED_ORIGINS)) {
    return json({ error: "origin_forbidden" }, 403);
  }
  const token = viewerTicketFromProtocols(request);
  if (!token) return json({ error: "ticket_required" }, 401);
  const ticket = await verifyViewerTicket(token, env.SHARE_TICKET_PUBLIC_KEYS_JSON, shareId);
  if (!ticket) return json({ error: "invalid_ticket" }, 401);
  return forwardSocket(request, env, shareId, "viewer", await viewerPrincipal(ticket));
}

function forwardSocket(
  request: Request,
  env: Env,
  shareId: string,
  role: "host" | "viewer",
  principal: Record<string, string>,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  const headers = new Headers(request.headers);
  headers.delete("authorization");
  headers.delete("x-cmux-share-capability");
  headers.set("x-cmux-share-role", role);
  headers.set("x-cmux-share-principal", encodePrincipal(principal));
  for (const [name, value] of Object.entries(extraHeaders)) headers.set(name, value);
  return roomStub(env, shareId).fetch(new Request(request.url, { headers }));
}

function roomStub(env: Env, shareId: string): DurableObjectStub<ShareRoom> {
  return env.SHARE_ROOM.get(env.SHARE_ROOM.idFromName(shareId));
}

function ownerIndexStub(env: Env, ownerUserId: string): DurableObjectStub<ShareOwnerIndex> {
  return env.SHARE_OWNER_INDEX.get(env.SHARE_OWNER_INDEX.idFromName(ownerUserId));
}

function hostPrincipal(user: ShareAuthedUser): Record<string, string> {
  return { userId: user.id, email: user.email, displayName: user.displayName };
}

async function viewerPrincipal(ticket: ShareViewerTicket): Promise<Record<string, string>> {
  return {
    userId: ticket.sub,
    email: ticket.primary_email,
    displayName: ticket.display_name,
    nonceHash: await capabilityHash(ticket.nonce),
    ticketExpiresAt: String(ticket.exp * 1_000),
  };
}

function originAllowed(request: Request, configured: string | undefined): boolean {
  const origin = normalizedOrigin(request.headers.get("origin"));
  if (!origin) return false;
  const allowed = new Set(
    (configured ?? "https://cmux.com")
      .split(",")
      .map(normalizedOrigin)
      .filter((value): value is string => !!value),
  );
  return allowed.has(origin);
}

function normalizedOrigin(value: string | null | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value.trim());
    const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
    return url.pathname === "/" && !url.search && !url.hash && !url.username && !url.password &&
      (url.protocol === "https:" || (url.protocol === "http:" && loopback)) ? url.origin : null;
  } catch {
    return null;
  }
}

function socketUrl(requestUrl: string, shareId: string): string {
  const url = new URL(requestUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = `/v1/shares/${shareId}/socket`;
  url.search = "";
  return url.toString();
}

function randomBase64Url(byteCount: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteCount));
  let raw = "";
  for (const byte of bytes) raw += String.fromCharCode(byte);
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
}

function encodePrincipal(value: Record<string, string>): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let raw = "";
  for (const byte of bytes) raw += String.fromCharCode(byte);
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "private, no-store",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}
