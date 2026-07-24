// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.
//
// cmux workspace share service — worker entry.
//
// Routes (see plans/feat-multiplayer-share/DESIGN.md):
//   GET  /healthz                  liveness, no auth
//   POST /v1/share/create          Stack bearer auth; body { title? };
//                                  returns { shareId, hostToken, url }
//   GET  /v1/share/:id/host        WebSocket upgrade, host lane
//                                  (?token=<hostToken>, verified in the DO
//                                  against the stored hash)
//   GET  /v1/share/:id/ws          WebSocket upgrade, viewer lane
//                                  (?access_token=<Stack access token>,
//                                  verified HERE; identity forwarded to the
//                                  DO via headers — the DO never sees
//                                  unauthenticated input)
//
// The DO id derives from the share id (idFromName), so one session's object
// can never be reached with another session's URL.

import { verifyAccessToken, verifyRequest, type AuthEnv } from "./auth";
import { generateHostToken, generateShareId, sha256Hex } from "./core";
import { ShareSession } from "./do";
import { parseCreateBody, parseSharePath, readBoundedJson } from "./validate";

export { ShareSession };

export interface Env extends AuthEnv {
  SHARE_SESSION: DurableObjectNamespace<ShareSession>;
}

// Browsers call create from the web app, so the endpoint answers CORS for the
// production origin plus localhost dev servers. WebSocket upgrades are not
// CORS-gated (the browser WS API sends no preflight); viewer auth is the
// verified access token, not the Origin header.
const ALLOWED_ORIGINS: ReadonlySet<string> = new Set([
  "https://cmux.com",
  "https://www.cmux.com",
]);

function corsOrigin(request: Request): string | null {
  const origin = request.headers.get("origin");
  if (!origin) return null;
  if (ALLOWED_ORIGINS.has(origin)) return origin;
  try {
    const url = new URL(origin);
    const isLocalHost = url.hostname === "localhost" || url.hostname === "127.0.0.1";
    if (isLocalHost && (url.protocol === "http:" || url.protocol === "https:")) return origin;
  } catch {
    // fall through
  }
  return null;
}

function corsHeaders(request: Request): Record<string, string> {
  const origin = corsOrigin(request);
  if (!origin) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-share" });
    }

    if (url.pathname === "/v1/share/create") {
      const cors = corsHeaders(request);
      if (request.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: cors });
      }
      if (request.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405, cors);
      }
      const user = await verifyRequest(request, env);
      if (!user) return json({ error: "unauthorized" }, 401, cors);
      const body = await readBoundedJson(request);
      if (!body.ok) return json({ error: "invalid_request" }, body.status, cors);
      const parsed = parseCreateBody(body.value);
      if (!parsed.ok) return json({ error: parsed.error }, 400, cors);

      const randomFill = (bytes: Uint8Array) => crypto.getRandomValues(bytes);
      const shareId = generateShareId(randomFill);
      const hostToken = generateHostToken(randomFill);
      const stub = env.SHARE_SESSION.get(env.SHARE_SESSION.idFromName(shareId));
      // Only the hash crosses into (and is stored by) the DO.
      const initialized = await stub.initialize(
        await sha256Hex(hostToken),
        {
          id: user.id,
          email: user.primaryEmail,
          name: user.displayName || user.primaryEmail,
        },
        parsed.title,
      );
      if (!initialized.ok) {
        // A 22-char base62 collision is effectively impossible; treat it as a
        // transient server error rather than looping.
        return json({ error: "share_id_collision" }, 500, cors);
      }
      return json(
        { shareId, hostToken, url: `https://cmux.com/share/${shareId}` },
        200,
        cors,
      );
    }

    const share = parseSharePath(url.pathname);
    if (share !== null) {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected_websocket" }, 426);
      }
      const stub = env.SHARE_SESSION.get(env.SHARE_SESSION.idFromName(share.shareId));

      if (share.lane === "host") {
        // The host token is verified inside the DO against the stored hash;
        // the worker just routes (it holds no per-session secrets).
        return stub.fetch(request);
      }

      // Viewer lane: verify the Stack access token HERE (query param because
      // browsers cannot set WS headers), then forward VERIFIED identity to
      // the DO via headers. Client-supplied x-share-* headers are overwritten
      // unconditionally, never passed through.
      const user = await verifyAccessToken(url.searchParams.get("access_token"), env);
      if (!user) return json({ error: "unauthorized" }, 401);
      const headers = new Headers(request.headers);
      headers.set("x-share-user-id", user.id);
      // Header values must be ISO-8859-1-safe; identity fields are free text.
      headers.set("x-share-email", encodeURIComponent(user.primaryEmail));
      headers.set("x-share-name", encodeURIComponent(user.displayName));
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
