// cmux share worker: routes WebSocket connects to the per-session Durable
// Object after verifying the share token offline (Ed25519, minted by the web
// API — see src/jwt.ts). Structure mirrors workers/presence.

import type { ShareWorkerEnv } from "./do";
import { ShareSession } from "./do";
import { verifyShareToken } from "./jwt";

export { ShareSession };

const WS_PATH = /^\/v1\/share\/sessions\/([A-Za-z0-9]{8,64})\/ws$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: ShareWorkerEnv): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-share" });
    }

    const match = WS_PATH.exec(url.pathname);
    if (match?.[1]) {
      const code = match[1];
      if (request.method !== "GET") {
        return json({ error: "method_not_allowed" }, 405);
      }
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected_websocket" }, 426);
      }
      if (!env.SHARE_JWT_PUBLIC_KEY) {
        // Fail closed when the trust anchor is not provisioned.
        return json({ error: "not_configured" }, 503);
      }
      // Browsers cannot set WebSocket headers, so the short-TTL token rides
      // the query string; native clients may use the Authorization header.
      const bearer = request.headers.get("authorization");
      const token =
        url.searchParams.get("token") ??
        (bearer?.toLowerCase().startsWith("bearer ") ? bearer.slice(7).trim() : null);
      if (!token) return json({ error: "unauthorized" }, 401);
      const claims = await verifyShareToken(token, code, env.SHARE_JWT_PUBLIC_KEY);
      if (!claims) return json({ error: "unauthorized" }, 401);

      const stub = env.SHARE_SESSION.get(env.SHARE_SESSION.idFromName(code));
      // Forward the upgrade with verified identity in headers the DO trusts.
      // The token never reaches the DO.
      const headers = new Headers(request.headers);
      headers.set("x-share-user", claims.sub);
      headers.set("x-share-email", claims.email);
      headers.set("x-share-host", claims.host ? "1" : "0");
      headers.set("x-share-code", code);
      const forward = new Request(url.origin + url.pathname, {
        method: "GET",
        headers,
      });
      return stub.fetch(forward);
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<ShareWorkerEnv>;
