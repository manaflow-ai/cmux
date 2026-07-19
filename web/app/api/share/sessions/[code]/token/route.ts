// Mint a connection token for an existing share code. Cookie auth is allowed —
// this is the browser path behind cmux.com/share/<code>. Whether the code
// refers to a live session is the Durable Object's decision at connect time;
// a token for a dead code is a signed 404.
//
// A `{"host": true}` body asks for a host-claim token; the host Mac uses this
// to reconnect after its create-time token expires. Minting it for any caller
// is safe: the session DO rejects a host-claim connection whose user id is
// not the session creator, so the claim only works for the actual host.

import type { KeyObject } from "node:crypto";

import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../../../services/vms/auth";
import {
  isValidShareCode,
  mintShareToken,
  shareSessionWsUrl,
  shareSigningKey,
} from "../../../../../../services/share/token";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export interface ShareGuestTokenDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
}

const productionDeps: ShareGuestTokenDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: true }),
  signingKey: shareSigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1000),
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleShareGuestToken(
  request: Request,
  code: string,
  deps: ShareGuestTokenDeps,
): Promise<Response> {
  if (!isValidShareCode(code)) return json({ error: "invalid_code" }, 400);
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();
  const key = deps.signingKey();
  if (!key) return json({ error: "share_not_configured" }, 503);
  let host = false;
  try {
    const body = (await request.json()) as { host?: unknown };
    host = body.host === true;
  } catch {
    // No/invalid body means a plain guest token.
  }
  const { token, expiresAt } = mintShareToken({
    sub: user.id,
    email: user.primaryEmail ?? "",
    code,
    host,
    key,
    nowSeconds: deps.nowSeconds(),
  });
  return json({ token, expiresAt, wsUrl: shareSessionWsUrl(code) });
}

export async function POST(
  request: Request,
  context: { params: Promise<{ code: string }> },
): Promise<Response> {
  const { code } = await context.params;
  return handleShareGuestToken(request, code, productionDeps);
}
