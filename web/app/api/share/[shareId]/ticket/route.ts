import { checkRateLimit } from "@vercel/firewall";
import type { KeyObject } from "node:crypto";
import { enforceBrowserMutationProtection, jsonResponse } from "../../../../../services/vms/routeHelpers";
import { verifyRequest, type AuthedUser } from "../../../../../services/vms/auth";
import {
  mintShareViewerTicket,
  shareSigningKey,
  shareSocketURL,
  type MintedShareTicket,
  type ShareTicketIdentity,
} from "../../../../../services/share/ticket";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export type ShareTicketRouteDeps = {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly signingKeyId: () => string | undefined;
  readonly socketOrigin: () => string | null;
  readonly mint: (input: {
    shareId: string;
    identity: ShareTicketIdentity;
    key: KeyObject;
    kid: string;
  }) => MintedShareTicket;
  readonly checkRateLimit: typeof checkRateLimit;
  readonly rateLimitId: () => string | undefined;
  readonly isVercel: () => boolean;
};

const productionDeps: ShareTicketRouteDeps = {
  verifyRequest: (request) => verifyRequest(request),
  signingKey: shareSigningKey,
  signingKeyId: () => process.env.CMUX_SHARE_TICKET_SIGNING_KID,
  socketOrigin: shareSocketURL,
  mint: mintShareViewerTicket,
  checkRateLimit,
  rateLimitId: () => process.env.CMUX_SHARE_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleShareTicketRequest(
  request: Request,
  shareId: string,
  deps: ShareTicketRouteDeps,
): Promise<Response> {
  if (!/^[A-Za-z0-9_-]{22}$/.test(shareId)) return privateJson({ error: "share_not_found" }, 404);
  const mutationForbidden = enforceBrowserMutationProtection(request);
  if (mutationForbidden) return mutationForbidden;
  const user = await deps.verifyRequest(request);
  if (!user) return privateJson({ error: "unauthorized" }, 401);

  if (deps.isVercel()) {
    const rateLimitId = deps.rateLimitId()?.trim();
    if (!rateLimitId) return privateJson({ error: "share_unavailable" }, 503);
    const result = await deps.checkRateLimit(rateLimitId, { request });
    if (result.rateLimited || result.error === "blocked") return privateJson({ error: "rate_limited" }, 429);
    if (result.error) return privateJson({ error: "share_unavailable" }, 503);
  }

  const key = deps.signingKey();
  const kid = deps.signingKeyId()?.trim();
  const socketOrigin = deps.socketOrigin();
  if (!key || !kid || !socketOrigin) return privateJson({ error: "share_unavailable" }, 503);
  const primaryEmail = user.primaryEmail?.trim();
  if (!primaryEmail || user.primaryEmailVerified !== true) {
    return privateJson({ error: "share_verified_email_required" }, 403);
  }
  const ticket = deps.mint({
    shareId,
    identity: {
      userId: user.id,
      primaryEmail,
      displayName: user.displayName?.trim() || primaryEmail,
    },
    key,
    kid,
  });
  return privateJson({
    socketUrl: `${socketOrigin}/v1/shares/${shareId}/socket`,
    protocols: ticket.protocols,
    expiresAt: ticket.expiresAt,
  });
}

export async function POST(
  request: Request,
  context: { params: Promise<{ shareId: string }> },
): Promise<Response> {
  const { shareId } = await context.params;
  return handleShareTicketRequest(request, shareId, productionDeps);
}

function privateJson(body: Record<string, unknown>, status = 200): Response {
  const response = jsonResponse(body, status);
  response.headers.set("cache-control", "private, no-store");
  response.headers.set("referrer-policy", "no-referrer");
  response.headers.set("x-content-type-options", "nosniff");
  return response;
}
