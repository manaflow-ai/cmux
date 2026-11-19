import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../../../../services/telemetry";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import { jsonResponse, parseBearer } from "../../../../services/vms/routeHelpers";
import { getStackServerApp } from "../../../lib/stack";

/**
 * Lifetime of a session minted for a local cmux build. It is the recipient's
 * own Stack session: signing out there revokes only it, and the caller's
 * session is never touched.
 */
export const SESSION_HANDOFF_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

const ROUTE = "/api/auth/session-handoff";
const MAX_REQUEST_BYTES = 4 * 1_024;
const NO_STORE = { "cache-control": "no-store" } as const;
// Labels only: they are recorded on the span and never authorize anything.
const BUNDLE_ID_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,254})$/;
const TAG_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,63})$/;

type Recipient = { readonly bundleId: string; readonly tag: string | null };

/**
 * Mints a new Stack session for the signed-in caller (a cmux app sending the
 * native `Authorization: Bearer <access>` + `X-Stack-Refresh-Token` pair), to
 * hand to a local cmux build of the same user. Tokens are never logged.
 */
export async function POST(request: Request): Promise<Response> {
  return withApiRouteSpan(
    request,
    ROUTE,
    { "cmux.auth.operation": "session_handoff.mint" },
    async (span) => {
      const bearer = parseBearer(request);
      if (!bearer) return unauthorized(span);

      const stackServerApp = getStackServerApp();
      let user: Awaited<ReturnType<typeof resolveServerUser>>;
      try {
        user = await resolveServerUser(stackServerApp, bearer);
      } catch (error) {
        return authProviderErrorResponse(error, "auth.session_handoff.auth");
      }
      if (!user) return unauthorized(span);

      const body = await readBoundedJsonObject(request, MAX_REQUEST_BYTES);
      if (!body.ok) {
        setSpanAttributes(span, { "cmux.auth.session_handoff.result": body.error });
        return jsonResponse(
          { error: body.error },
          body.error === "request_too_large" ? 413 : 400,
          NO_STORE,
        );
      }
      const recipient = parseRecipient(body.value.recipient);
      if (!recipient) {
        setSpanAttributes(span, { "cmux.auth.session_handoff.result": "invalid_recipient" });
        return jsonResponse({ error: "invalid_recipient" }, 400, NO_STORE);
      }
      setSpanAttributes(span, {
        "cmux.auth.session_handoff.recipient_bundle_id": recipient.bundleId,
        "cmux.auth.session_handoff.recipient_tag": recipient.tag,
      });

      let tokens: { accessToken?: string | null; refreshToken?: string | null };
      const mintedAtMs = Date.now();
      try {
        const session = await user.createSession({ expiresInMillis: SESSION_HANDOFF_LIFETIME_MS });
        tokens = await session.getTokens();
      } catch (error) {
        recordSpanError(span, error);
        setSpanAttributes(span, { "cmux.auth.session_handoff.result": "mint_failed" });
        return jsonResponse({ error: "session_unavailable" }, 503, NO_STORE);
      }
      if (!tokens.accessToken || !tokens.refreshToken) {
        setSpanAttributes(span, { "cmux.auth.session_handoff.result": "mint_incomplete" });
        return jsonResponse({ error: "session_unavailable" }, 503, NO_STORE);
      }

      setSpanAttributes(span, { "cmux.auth.session_handoff.result": "minted" });
      return jsonResponse(
        {
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiresAt: new Date(mintedAtMs + SESSION_HANDOFF_LIFETIME_MS).toISOString(),
        },
        200,
        NO_STORE,
      );
    },
  );
}

// The caller's tokens resolve its identity; the server-side user for that id is
// the one that can mint a session (as in /api/vault/cli/auth/poll).
async function resolveServerUser(
  stackServerApp: ReturnType<typeof getStackServerApp>,
  bearer: { readonly accessToken: string; readonly refreshToken: string },
) {
  const caller = await stackServerApp.getUser({
    tokenStore: { accessToken: bearer.accessToken, refreshToken: bearer.refreshToken },
  });
  if (!caller || caller.isAnonymous) return null;
  return stackServerApp.getUser(caller.id);
}

function unauthorized(span: Parameters<typeof setSpanAttributes>[0]): Response {
  setSpanAttributes(span, { "cmux.auth.session_handoff.result": "unauthorized" });
  return jsonResponse({ error: "unauthorized" }, 401, NO_STORE);
}

function parseRecipient(value: unknown): Recipient | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const { bundleId, tag } = value as Record<string, unknown>;
  if (typeof bundleId !== "string" || !BUNDLE_ID_PATTERN.test(bundleId)) return null;
  if (tag === null) return { bundleId, tag: null };
  if (typeof tag !== "string" || !TAG_PATTERN.test(tag)) return null;
  return { bundleId, tag };
}
