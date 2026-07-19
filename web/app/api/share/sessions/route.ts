// Create a workspace share session: mint the share code and the host token.
// Native-only auth (the host is the macOS app); the browser guest path is
// app/api/share/sessions/[code]/token/route.ts. The session itself
// materializes in the share worker's Durable Object when the host connects —
// there is no database row, the code+token pair is the whole grant.

import type { KeyObject } from "node:crypto";

import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";
import {
  generateShareCode,
  mintShareToken,
  sharePageUrl,
  shareSessionWsUrl,
  shareSigningKey,
} from "../../../../services/share/token";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export interface ShareSessionCreateDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
  readonly generateCode: () => string;
}

const productionDeps: ShareSessionCreateDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  signingKey: shareSigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1000),
  generateCode: generateShareCode,
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleShareSessionCreate(
  request: Request,
  deps: ShareSessionCreateDeps,
): Promise<Response> {
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();
  const key = deps.signingKey();
  if (!key) return json({ error: "share_not_configured" }, 503);
  const code = deps.generateCode();
  const { token, expiresAt } = mintShareToken({
    sub: user.id,
    email: user.primaryEmail ?? "",
    code,
    host: true,
    create: true,
    key,
    nowSeconds: deps.nowSeconds(),
  });
  return json({
    code,
    token,
    expiresAt,
    wsUrl: shareSessionWsUrl(code),
    shareUrl: sharePageUrl(code),
  });
}

export async function POST(request: Request): Promise<Response> {
  return handleShareSessionCreate(request, productionDeps);
}
